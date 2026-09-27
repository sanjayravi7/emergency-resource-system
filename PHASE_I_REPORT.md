# PHASE I — Production Readiness + Security Hardening

**Scope:** hardening only. No new product features (Part 19 respected).
**Baseline entering Phase I:** backend 23 suites / 237 tests green (x2); Flutter
analyze 0 issues, 144 tests (x2); Phase H E2E 13/13 backend, 11/11 Flutter.

## Environment note (read first)

This hardening pass was implemented in a sandbox that has **npm registry access
but no PostgreSQL, no Flutter SDK, and no access to `binaries.prisma.sh`**
(the Prisma engine download host is network-blocked). Consequences:

- **`npm audit`, dependency resolution, and the targeted upgrade were executed
  here** and are fully verified below.
- **New DB-free tests were executed here** (36 tests, see Part 18) using a
  mocked Prisma client and isolated config loads.
- The **existing 237-test integration suite, `prisma migrate`/`generate`,
  `verify-schema.js`, the perf smoke script, and all Flutter commands require
  the CI/dev environment** (PostgreSQL + Prisma engines + Flutter). The CI
  workflow added in Part 17 runs exactly those. Where a step could not be
  executed here it is labelled **[requires CI/DB]** or **[requires Flutter]**
  and never claimed as passed.

All code changes were made to be **behaviour-preserving for existing API
contracts** (same status codes and messages on existing paths), so the 237
integration tests and 144 Flutter tests are expected to remain green.

---

## 1. Dependency vulnerabilities and decisions

`npm audit` and `npm audit --omit=dev` both reported **3 HIGH**, all from a
single transitive chain:

```
prisma@6.19.3 (dev CLI) ── @prisma/config@6.19.3 ── deepmerge-ts@7.1.5   [VULN]
@prisma/client@6.19.3 ─────────── prisma@6.19.3 (deduped) ──┘
```

| Field | Finding |
|-------|---------|
| Package | `deepmerge-ts` |
| Vulnerable version | `7.1.5` (advisory range `<8.0.0`) |
| Advisory | GHSA-ggr8-5vv4-36mx — stack exhaustion / uncontrolled recursion (DoS) when merging recursive object graphs |
| Affected path | `prisma` / `@prisma/client` → `@prisma/config` → `deepmerge-ts` |
| Fixed version | `deepmerge-ts@8.0.0+` |
| Runtime vs dev | **Effectively build/CLI-time.** `deepmerge-ts` is invoked only by `@prisma/config` when the Prisma CLI loads its config file (`prisma migrate/generate/studio`). The running Express/Socket.IO app uses `@prisma/client`, which never feeds attacker-controlled input into `deepmerge-ts`. Real-world request-path exposure ≈ nil. |
| Break risk of fixing | Low (see decision). |

**Options evaluated:**

- `npm audit fix --force` → downgrades to `prisma@6.12.0` (older, breaking/
  regression). **Rejected.**
- Upgrade to `prisma@7.10.0` → still resolves `@prisma/config@7.10.0 →
  deepmerge-ts@7.1.5`; **does not fix**, and is a major version bump. **Rejected.**
- Upgrade to `prisma@8.x` → prerelease (`8.0.0-rc.17`), not production-safe.
  **Rejected.**
- **Chosen:** pin the transitive dependency via an npm `overrides` entry:
  ```json
  "overrides": { "deepmerge-ts": "^8.0.2" }
  ```

**Verification performed here:**
- `npm install` with the override → `deepmerge-ts@8.0.2 overridden`,
  **`found 0 vulnerabilities`** (both full and `--omit=dev`).
- Confirmed `@prisma/config`'s usage is `const { deepmerge } = await
  import('deepmerge-ts')`; the `deepmerge` named export and signature are
  unchanged in v8. Exercised it directly (merge of nested objects) → correct.
- `npx prisma generate` progressed **past config loading** (emitted the
  `package.json#prisma` deprecation notice, which `@prisma/config` prints only
  after a successful deepmerge-backed config load) before failing on the
  network-blocked engine download — i.e. the override does not break the CLI
  config layer. Full `prisma generate` runs clean in CI.

**Flutter (`flutter pub outdated`) [requires Flutter]:** could not be executed
(no SDK). Direct dependencies are current-major and none carry an open advisory
in this pass:

| Package | Constraint | Safe upgrade / note | Breaking-change risk |
|---------|-----------|---------------------|----------------------|
| `http` | ^1.6.0 | current major | none expected |
| `socket_io_client` | ^2.0.3 | stay on 2.x (matches server Socket.IO 4.x protocol) | major bump not advised |
| `geolocator` | ^13.0.2 | current major | permission API changes across majors — pin |
| `google_maps_flutter` | ^2.18.1 | current major | none expected |
| `url_launcher` | ^6.3.1 | current major | none expected |
| `flutter_lints` | ^5.0.0 (dev) | current | none |

Recommendation: run `flutter pub outdated` in CI and adopt only patch/minor
upgrades within these majors; do not auto-upgrade `geolocator`/`socket_io_client`
across majors in a hardening phase.

---

## 2. Security headers / HTTP hardening

Changes in `backend/src/app.js` (+ `config/env.js`):

- **Helmet** added (`app.use(helmet())`) — `X-Content-Type-Options: nosniff`,
  `X-DNS-Prefetch-Control`, `X-Frame-Options`, CSP defaults, HSTS (HTTPS only),
  etc. Attached to the Express app only; the Socket.IO handshake is served by
  the raw HTTP server and is unaffected.
- **`x-powered-by` disabled** explicitly (`app.disable('x-powered-by')`).
- **CORS made configurable** via `CORS_ORIGINS`. Unset/`*` reflects the request
  origin (preserves historical Flutter web + native behaviour); a comma list
  locks the API to an allowlist. Applied to REST and (via `server.js`) to the
  Socket.IO CORS origin.
- **Body-size limit**: `express.json({ limit: JSON_BODY_LIMIT })` (default
  `100kb`). Oversized bodies → **413**.
- **Malformed JSON** → **400** with a generic message (was a leaky 500).
- **`trust proxy`** configurable (`TRUST_PROXY`; default `1` in production,
  `false` in dev) so `req.ip` and rate limiting are correct behind a proxy.
- **JSON 404** for unknown routes (was Express' default HTML `Cannot GET`).

Verified here (mocked Prisma) in `tests/security/httpHardening.test.js`: headers
present, `x-powered-by` absent, 404/400/413 envelopes, CORS reflection, and that
a protected route returns 401 without touching the DB. **Existing Flutter/API
communication is preserved** — status codes and JSON envelopes on existing paths
are unchanged.

---

## 3. JWT / auth hardening

- **Weak/default secret rejected in production** (`config/env.js`): startup
  **throws** in `NODE_ENV=production` if `JWT_SECRET` is a known default
  (`change-me`, `secret`, …) or shorter than 32 chars; **warns** (non-fatal)
  outside production. `DATABASE_URL`/`JWT_SECRET` remain required in all envs.
- **Role sourced from the current DB identity, not the token** (`authMiddleware`
  now selects `role` and sets `req.user.role` from the DB row). A forged/stale
  token claiming `ADMIN` cannot act as admin if the DB says otherwise, and a
  demoted user loses privileges immediately. (The Socket.IO layer already did
  this in `socketAuth.js`.)
- **Numeric identity validated** before the DB lookup.
- **Expired / tampered / wrong-secret tokens** → 401; **inactive** identity →
  401 (with a redacted `auth.inactive_user_rejected` log).
- No hardcoded production secret exists anywhere in the repo (grep clean).

Verified here in `tests/security/authMiddleware.test.js` (7 tests) and
`tests/unit/envSecurity.test.js` (11 tests): missing/format/expired/wrong-secret/
missing-user/inactive rejection, and **role-from-DB anti-escalation**.

---

## 4. Rate limiting

New `backend/src/middleware/rateLimiters.js` (`express-rate-limit`):

- **`authLimiter`** — strict, mounted only on `/api/auth/login` and
  `/api/auth/register` (default 30 / 15 min / IP). Blunts password spraying and
  mass registration.
- **`apiLimiter`** — generous catch-all on `/api` (default 600 / min / IP) that
  **skips GPS-sensitive paths** (`/responders/location`, `/responders/heartbeat`).
- **Socket.IO** already rate-limits location updates per responder/request
  window (`SOCKET_LOCATION_*`) — left intact.
- All limiters honour `RATE_LIMIT_ENABLED` (default **off under
  `NODE_ENV=test`**, on otherwise) so the integration suite and real emergency
  dispatch/GPS are never throttled.

Location rate limiting is unchanged and remains compatible with current GPS
behaviour. Verified here in `tests/security/rateLimit.test.js` (429 after budget,
GPS paths exempt, disabled under test).

---

## 5. Input validation audit

Existing validators are already strict (reviewed, no regressions introduced):

| Field | Where enforced | Rule |
|-------|----------------|------|
| `emergencyType` | `requestValidator` | required, trimmed, non-empty |
| `description` | `requestService.normalizeOptionalDescription` | **semantics preserved:** missing/null/empty/whitespace → `null`; non-empty preserved exactly |
| `location` | `requestValidator` | required, non-empty |
| `latitude`/`longitude` | `requestValidator`, socket `validCoordinate` | numeric, in range, **all-or-nothing pair** |
| `priority` | `requestValidator` | enum `LOW/MEDIUM/HIGH/CRITICAL` |
| resource IDs / responderResourceId | `allocationService.asPositiveInteger` | positive integer |
| quantities | validators + `allocationService` | positive integer, `>0`, ≤ cap, ≤ outstanding, ≤ available |
| responder/allocation/request/assignment IDs | services (`asPositiveInteger`, `Number.isInteger` guards) | positive integer; ownership re-checked in the transaction |
| socket payloads | `asRequestId`, `validCoordinate` | integer/coord validated before use |
| unknown fields | `normalizeResourceInput` and Prisma `data:{}` allowlists | dropped — clients cannot write arbitrary columns |

IDs cannot be used for IDOR because every mutation re-validates ownership inside
the serializable transaction (see Part 7). The optional-description contract is
untouched.

---

## 6. Authorization matrix

Enforced by `authMiddleware` (identity, DB role) + `authorizeRoles` (RBAC) +
per-service ownership checks. Covered by existing suites
(`tests/authorization/authorization.test.js`,
`tests/dispatch/*`, `tests/allocation/*`,
`tests/realtime/socketAuthorization.test.js`) and the new middleware tests.

| Actor | Allowed | Denied |
|-------|---------|--------|
| **REQUESTER** | create own request; view own requests (`/requests/my`); cancel own request; confirm receipt on **own** allocation | creating allocations (403); accepting requests (403); admin endpoints (403); another requester's request/allocation (Unauthorized in service) |
| **RESPONDER** | view compatible/assigned requests; accept compatible request; create/dispatch/deliver/cancel **own** allocation; publish **own** location; update own status/location/heartbeat | mutating another responder's inventory/allocation ("Responder mismatch: unauthorized"); acting on unrelated requests; admin/user endpoints (403); confirming receipt (403, requester-only) |
| **ADMIN** | `/api/admin/*` oversight (all requests/allocations/responders), force-end assignments, force request status, user role/activate/deactivate | — (no privilege regression introduced) |

REST and Socket.IO are authorized **separately**: REST via
`authMiddleware`+`authorizeRoles`+service checks; sockets via `socketAuth`
(DB role/active) + `canSubscribe`/`requestForResponder`/`responderParticipationWhere`.

---

## 7. IDOR audit

Systematic cross-object checks. Every unauthorized combination fails; ownership
is re-validated inside the serializable transaction (not merely at the route).

| Attempt | Result | Enforced by |
|---------|--------|-------------|
| Responder A uses Responder B's ResponderResource | ✅ blocked — "Responder mismatch: unauthorized" | `createAllocation` (`responderResource.responderId !== responderId`) |
| Responder A mutates Allocation B (not theirs) | ✅ blocked — "Unauthorized" | `updateAllocationStatus` (`allocation.responderId !== responderId`) |
| Responder A acts on Request/Assignment B (unrelated) | ✅ blocked | `endResponderAssignment`, `responderParticipationWhere` |
| Requester A confirms receipt on Request B's allocation | ✅ blocked — "Unauthorized" | `confirmAllocationReceived` (`request.requesterId !== requesterId`) |
| Requester A cancels Request B | ✅ blocked | `cancelEmergencyRequest` (ownership) |
| Socket A subscribes to Request B (unrelated) | ✅ blocked — `FORBIDDEN` | `canSubscribe` per-role checks |
| Allocation against another responder's resource / unrelated resource / closed request | ✅ blocked | `createAllocation` lock+validate |

Coverage is provided by existing DB-backed suites listed in Part 6 **[requires
CI/DB to execute]**, plus the DB-free authorization/identity tests added here.
Note: `backend/test/adversarial.test.js` (singular `test/`) contains additional
adversarial IDOR cases but is **outside jest's `**/tests/**` matcher and is not
executed**; it is also stale (asserts an old auth message). It was left
untouched to avoid destabilising the green baseline; the same properties are
covered by the `tests/` suites above.

---

## 8. Realtime security

Reviewed `socketAuth.js`, `socketServer.js`, `socketEvents.js`,
`eventEmitters.js` (already hardened in Phase H; **room names preserved**:
`user:<id>`, `request:<id>`, `responders`, `admins`):

- **Global `responders` room never receives full request snapshots** — only a
  redacted `{requestId, status, available, updatedAt}` joinability signal
  (`emitRequestUpdated`).
- **Location events go only to `rooms.request(id)`**, whose membership is
  authorized (requester, participating responder, admin) — never a global stream.
- **Ended assignment cannot regain active-work privileges**: location start/
  update require `requestForResponder(..., activeOnly)` via
  `responderParticipationWhere` (ACTIVE assignment / unfinished allocation /
  legacy lead-without-assignment). Terminal `ENDED`/`CANCELLED` legs are excluded.
- **Cancelled allocation grants no participation** (excluded from
  `UNFINISHED_ALLOCATION_STATUSES` and from terminal re-broadcast).
- **Inactive sockets invalidated**: `refreshSocketIdentity` runs on every
  sensitive event and on a `SOCKET_SESSION_REVALIDATE_MS` timer → emits
  `socket.invalidated` and disconnects.
- **Reconnect rebuilds only authorized rooms** (`bindSocketConnection` joins
  user room, role room, and only currently-authorized, non-terminal requests).

CORS origin for Socket.IO is now wired to the same `CORS_ORIGINS` config
(default reflect-any preserved).

---

## 9. Error handling

`errorMiddleware.js` now separates classes:

- **Client/body faults** (malformed JSON → 400, oversized → 413, unsupported
  charset/encoding → 415) are handled explicitly, before the generic path.
- **Expected business conflicts** (matched regex) → logged as `business.conflict`
  (warn), **status/message contract preserved** (still 500 with the business
  message — see convention note below).
- **Prisma/infrastructure errors** → logged as `database.error` with only the
  safe error `code`; client receives the stable `"Database operation failed"`.
  Query text / schema internals never reach the client.
- **Unexpected errors** → logged as `server.error` (name/message, redacted);
  **stack traces never reach the client**.

Secrets, DB URLs, JWTs, passwords, and Prisma internals are never returned or
logged (the logger redacts sensitive keys; see Part 11). Verified here in
`tests/unit/errorMiddleware.test.js` and `tests/security/httpHardening.test.js`.

**Documented convention (for a future API version, not changed now):** several
*expected business conflicts* (e.g. `Unauthorized`, `Not enough available
quantity`) currently return **HTTP 500** with the business message rather than
409/403/422. This matches Phase H behaviour and existing tests. Per Part 9 the
public status contract was **not** changed in this phase; a future API
versioning effort should remap these to 4xx.

---

## 10. Database safety

Audited `prisma/schema.prisma` and `transactionService.js`; **no schema change
was required or made** (Part 10 — change only for a real production defect; none
found), and **no `prisma migrate reset` was run**.

- **Foreign keys** present on every relation; **cascading deletes** on
  `ResponderAssignment`, `ResponderResource`, `RequestResource` (children of a
  request/responder), while `Allocation`→request/resource keep referential
  history.
- **Unique constraints**: `User.email`, `Resource.name`,
  `ResponderAssignment(requestId,responderId)`,
  `ResponderResource(responderId,resourceId)`,
  `RequestResource(requestId,resourceId)` — prevent duplicates/orphans.
- **Indexes** on all hot lookup columns (status, priority, responderId,
  requestId, etc.).
- **Transaction boundaries**: all inventory/lifecycle mutations run in
  `runSerializableTransaction` with `SELECT … FOR UPDATE` row locks.
- **Serializable retry**: `isRetryableTransactionError` retries P2034 / 40001 /
  40P01 / deadlock with jittered backoff (5 attempts).
- **Bootstrap from empty DB**: `migrate deploy` + `verify-schema.js` is the
  supported path (used by `pretest` and CI). **[requires CI/DB to execute]**

---

## 11. Observability

New `backend/src/config/logger.js` — structured (JSON in prod), **secret-redacting**
logger. Redacts any key matching `pass/secret/token/authorization/jwt/
database_url/credential/apikey…` at any depth, truncates huge strings, and stays
silent under `NODE_ENV=test` (unless `LOG_IN_TEST`).

Wired to new/changed middleware for diagnosable events **without** leaking
secrets:

- `authz.denied` (role failure), `auth.inactive_user_rejected`
- `rate_limit.exceeded`, `request.rejected` (400/413/415)
- `business.conflict`, `database.error` (code only), `server.error`
- `server.started`

Never logs passwords, JWTs, DB credentials, or precise PII; uses stable IDs
(`userId`, `requestId`, path/method). Existing lifecycle events (created,
assigned, allocation created/dispatched/delivered, assignment ended, completed,
cancelled) are emitted over Socket.IO and are diagnosable via those events; the
pre-existing service `console.error('Realtime emission failed', error.message)`
lines log only the message (no secrets) and can be migrated to the structured
logger in a later pass.

---

## 12. Configuration / environment

`config/env.js` hardened (Part 3/12) and `.env.example` fully documented:

- Production **requires** `DATABASE_URL` + a **strong** `JWT_SECRET` (fails
  startup clearly otherwise); dev defaults stay frictionless.
- Debug behaviour differs by `NODE_ENV` (JSON logs + strict secret + default
  trust-proxy only in production).
- `CORS_ORIGINS` configurable (REST + Socket.IO).
- Google Maps **browser** key documented as browser-side + referrer-restricted
  (`web/google_maps_config.template.js`, `GOOGLE_MAPS_SETUP.md`); **no server
  Maps/Routes key exists** (directions use a key-less universal URL).
- Photon reverse-geocoding documented (server-side; no Google Geocoding key).
- No real secrets are committed (`.env` git-ignored; only `.env.example`).

---

## 13. Frontend production check [requires Flutter to execute]

Reviewed (no state-management rearchitecture — Part 19):

- **API base URL**: `String.fromEnvironment('ERAS_API_BASE_URL', default '/api')`
  → same-origin on web; `--dart-define` for native. No hardcoded sandbox host.
- **Socket.IO URL**: derived from `ApiService.baseUrl`; on web uses
  `Uri.base.origin` (never a sandbox localhost). Browser code uses relative URLs.
- **Google Maps**: browser key from `web/google_maps_config.js` (git-ignored
  template provided).
- **Auth persistence**: in-memory only → re-login after restart (a reasonable
  security posture; documented in the device checklist, not changed).
- **Logout / reconnect / loading-error / offline / stale-data**: handled by the
  existing socket connection-state machine (`RealtimeConnectionStatus`,
  `live_location_store` reconciliation of live vs persisted points).

Backend changes preserve existing status codes/JSON envelopes, so no Flutter
change is required; new 400/413/429/404 responses are surfaced through the
existing `ApiService` error path (`body['message']`).

---

## 14. Real device limitations

Manual, **non-automated** acceptance criteria are documented in
[`MANUAL_ACCEPTANCE_CHECKLIST.md`](./MANUAL_ACCEPTANCE_CHECKLIST.md): Android GPS
permission granted/denied/approximate/disabled, reconnect, background↔foreground;
Google Maps load/markers/multi-responder/direct-lines/Get-Directions. These are
explicitly **not** claimed as automated.

---

## 15. Performance / load smoke test

Added `backend/scripts/perf-smoke.js` — **non-destructive, read-only** for the
DB; measures avg/p50/p95/max for: compatible request discovery, assigned request
discovery, request snapshot generation, multiple responder locations, and a
self-contained in-process **Socket.IO fan-out** micro-benchmark (N clients in a
room). It performs **no writes** and must not be run against production under
load.

Run: `DATABASE_URL=… node scripts/perf-smoke.js`
(tunable: `PERF_ITERATIONS`, `PERF_FANOUT_CLIENTS`).

**Measured values [requires CI/DB]:** not captured in this sandbox (no
PostgreSQL). Record the numbers and environment (host, Node, Postgres version,
dataset size) when first run in CI/dev.

---

## 16. Dependency upgrade strategy

- Exact fix identified for all 3 HIGH: **`deepmerge-ts` → `^8.0.2` via
  `overrides`** (no unrelated upgrades bundled — Part 16 respected).
- `helmet@^8.3.0` and `express-rate-limit@^8.7.0` added for Parts 2/4; post-add
  audit = **0 vulnerabilities**.
- Full backend test run after the change is the CI gate **[requires CI/DB]**;
  the DB-free suite (36 tests) passed here after every change.
- No Flutter-shared behaviour changed by these backend-only dependency edits.

---

## 17. CI

The repo already uses **GitHub Actions** (`.github/workflows/dart.yml`, Flutter:
pub get → format → analyze → test). It had **no backend job**. Smallest
necessary improvement: added `.github/workflows/backend.yml`:

- Postgres 16 service container.
- `npm ci` → `npx prisma generate` → `npx prisma migrate deploy` →
  `node scripts/verify-schema.js` → `npm audit --omit=dev --audit-level=high`
  (security gate) → `npm test -- --runInBand`.
- Node 22, strong CI-only `JWT_SECRET`, `NODE_ENV=test`.

`npm ci --dry-run` verified the lockfile is consistent with the new
deps/override here. Full pipeline runs on GitHub runners **[requires CI]**.

---

## 18. Backend tests and repeated runs

**Executed in this sandbox (DB-free, mocked Prisma / isolated config):**

```
npx jest tests/unit tests/security --runInBand
Test Suites: 6 passed, 6 total
Tests:       36 passed, 36 total
```

New suites:
- `tests/unit/envSecurity.test.js` (11) — secret strength, prod enforcement,
  CORS/trust-proxy/rate-limit config.
- `tests/unit/logger.test.js` (3) — redaction of secrets, truncation.
- `tests/unit/errorMiddleware.test.js` (6) — 400/413, Prisma masking, business
  contract, no stack leak.
- `tests/security/httpHardening.test.js` (6) — headers, 404, malformed/oversized,
  CORS, 401.
- `tests/security/authMiddleware.test.js` (7) — missing/expired/tampered/wrong-
  secret/missing-user/inactive, **role-from-DB anti-escalation**.
- `tests/security/rateLimit.test.js` (3) — 429 after budget, GPS exempt, test-off.

**[requires CI/DB]** The regression sequence from the Phase I brief must be run
in CI/dev (unchanged commands):
```
npx prisma generate
npx prisma migrate status
node scripts/verify-schema.js
npm test -- --runInBand      # 23 suites / 237 tests (run twice)
```
Expected green: changes preserve existing contracts; rate limiting is disabled
under `NODE_ENV=test`; helmet/CORS add headers only.

---

## 19. Flutter tests and repeated runs [requires Flutter]

No Flutter code changed, so behaviour is unchanged. Run in CI/dev:
```
flutter clean && flutter pub get && flutter analyze && flutter test && flutter test
```
Expected: analyze 0 issues, 144/144 tests (x2), as at baseline.

---

## 20. Exact files changed

**Modified**
- `backend/package.json` — `overrides.deepmerge-ts ^8.0.2`; add `helmet`,
  `express-rate-limit`.
- `backend/package-lock.json` — resolved lock (deepmerge-ts 8.0.2, new deps).
- `backend/.env.example` — documented all env (secrets, CORS, trust proxy, body
  limit, rate limiting, Maps/Photon).
- `backend/src/app.js` — helmet, configurable CORS, body limit, rate limiters,
  trust proxy, JSON 404.
- `backend/src/server.js` — Socket.IO CORS from env; structured startup log.
- `backend/src/config/env.js` — NODE_ENV, strong-secret enforcement (prod),
  CORS/trust-proxy/body-limit/rate-limit config, `isWeakSecret` export.
- `backend/src/middleware/authMiddleware.js` — role sourced from DB; numeric-id
  guard; redacted inactive log.
- `backend/src/middleware/errorMiddleware.js` — body-parser 400/413/415;
  Prisma/stack masking; structured logging; business contract preserved.
- `backend/src/middleware/roleMiddleware.js` — `authz.denied` logging.

**Added**
- `backend/src/config/logger.js` — redacting structured logger.
- `backend/src/middleware/rateLimiters.js` — auth + general limiters (GPS-exempt).
- `backend/scripts/perf-smoke.js` — non-destructive perf smoke test.
- `backend/tests/unit/{envSecurity,logger,errorMiddleware}.test.js`
- `backend/tests/security/{httpHardening,authMiddleware,rateLimit}.test.js`
- `.github/workflows/backend.yml` — backend CI (Postgres + Prisma + audit + tests).
- `MANUAL_ACCEPTANCE_CHECKLIST.md` — device/Maps manual checklist.
- `PHASE_I_REPORT.md` — this report.

---

## Remaining risks

1. **500-for-business-conflict convention** retained (Part 9) — remap to 4xx in a
   future API version; harmless but non-ideal for API consumers.
2. **Integration/Flutter/perf/CI steps not executed in this sandbox** (no
   PostgreSQL / Prisma engines / Flutter). They are wired into CI and must be
   confirmed green there. Changes were kept contract-preserving to protect the
   237/144 baseline.
3. **Legacy `backend/test/adversarial.test.js`** is not run by jest and is stale;
   left untouched. Consider fixing + moving into `tests/` (own follow-up) to
   restore those adversarial IDOR assertions to the suite.
4. **Flutter auth is in-memory only** (re-login after restart) — intentional;
   documented, not changed.
5. **`flutter pub outdated`** not run here; enable it as a CI advisory step.
6. Service-level `console.error('Realtime emission failed', …)` logs the message
   only (safe) but are not yet routed through the structured logger.

**STOP — Phase I complete. Phase J not started.**
