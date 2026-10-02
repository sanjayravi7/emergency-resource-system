# ERAS integration + security hardening — final report

Branch: `arena/01a0f9c9-emergency-resource-system` · PR: #68 · final commit: `921bef4`
(87 files changed vs. `3817807`: +10,697 / −425.)

This report states only what was actually executed or read. Where a
verification could not be performed in this environment, item 11 names the
exact command and the exact blocker instead of implying success.

---

## 1. What was delivered, in one table

| # | Requirement | Where it lives | State |
| --- | --- | --- | --- |
| 1 | Google registration/login through the existing Firebase project, server-verified, REQUESTER/RESPONDER only | `backend/src/services/{firebaseTokenService,googleAuthService}.js`, `controllers/authController.googleSignIn`, `POST /api/auth/google`; `frontend/.../services/{firebase_bootstrap,google_auth_service}.dart`, `web/index.html`, `android/*/build.gradle.kts` | Implemented, unit-tested; live Google exchange not runnable here (item 11) |
| 2 | First-login email verification (6-digit, ERAS-branded, resend + rate limit, refresh, skip for Google) | `services/{authCodeService,emailVerificationService,emailService}.js`, `screens/email_verification_screen.dart` | Implemented, tested |
| 3 | Strict email validation client + server, no SMTP probing | `backend/src/domain/emailValidation.js`, `frontend/.../services/email_validation.dart` | Implemented, tested (unit + API) |
| 4 | Forgot password by 6-digit emailed code | `services/passwordResetService.js`, `routes/authRoutes.js`, `screens/forgot_password_screen.dart` | Implemented, tested end-to-end |
| 5 | Automatic location-permission request after entering the authenticated app (existing service, no lockout) | `dispatch_console_page._initializeLocationPermission/_retryLocationPermission`, `widgets/location_permission_banner.dart` | Implemented, tested |
| 6 | Auto-start live location after ACCEPT; never roll back; stop on complete/end/logout; no duplicate watchers | `dispatch_console_page.{acceptRequest,_autoStartLiveLocationSharing,startLocationSharing,stopLocationSharing}` | Implemented, tested |
| 7 | True 24-hour `HH:MM:SS` timer, no app-wide rebuilds | `widgets/common_widgets.dart` (`formatErasClock`, `ErasClock`) | Implemented, tested |
| 8-11 | Copy changes (“No active request is available”, “Live request state”, “Responders registered”, “Responders data”) | `dispatch_console_page.dart`, `widgets/*` | Implemented, source-guarded by tests |
| 12 | Responder privacy enforced by the API (email/phone never sent to non-admins) | `backend/src/domain/privacy.js` + all serializers | Implemented, backend + widget tested |
| 13 | ADMIN-only log deletion with a preserved security audit record | `adminController.deleteLogEntry`, `requestService.archiveRequestForAdmin`, `widgets/log_panel.dart` | Implemented, tested |
| 14-28 | Backend hardening (validation, XSS, uploads, hashing, sessions, CSRF decision, headers/CSP, rate limits, error shape, mass assignment, RBAC, CORS, payload limits, `npm audit`) | see item 6 | Implemented; audits run |
| 29-32 | Inventory layout collision, GET DIRECTIONS states, dark theme preserved, requester/responder contact privacy in every widget | `widgets/{resource_panels,responder_readiness_page,operational_google_map,board_panel,log_panel}.dart` | Implemented, tested |
| 33 | APK builds from the current source with the production API base URL | verified in CI (item 5) | Verified |
| 34-36 | No destructive migrations, lifecycle and multi-responder semantics preserved | `prisma/migrations/20261001120000_*` only | Verified by the existing suites |
| 37-41 | Backend + Flutter tests, `dart format`, `flutter analyze`, `flutter test`, `npm test`, `npm audit`, web/APK release builds | item 5 | Verified |
| 42 | This report | — | — |

## 2. Automatic expiry of unattended requests (backend-authoritative)

`backend/src/domain/expiryPolicy.js` is the single source of truth:

| Class | Window | Matched by |
| --- | --- | --- |
| URGENT | 30 min | medical / fire / accident / rescue / flood, or `CRITICAL` priority |
| SUPPLY | 240 min | food, water, relief, supply, ration, grocery, blanket, clothing, shelter, medicine, oxygen, inventory, kit, provisions |
| GENERAL | 60 min | everything else |

`EXPIRY_{URGENT,GENERAL,SUPPLY}_MINUTES` override the defaults (clamped 1–1440)
and are read per call, so a redeploy takes effect immediately. A request is
expired only when it is past `expiresAt` **and** `PENDING` **and** has no
acceptor, no `ACTIVE` assignment and no `RESERVED`/`DISPATCHED` allocation —
accepted, in-progress, completed and cancelled work never expires.

Durability: expiry is a persisted transition (`CANCELLED` + `expiredAt`) on a
row-locked re-check (`SELECT … FOR UPDATE`), so it survives a Render sleep or
restart; the 60-second sweep in `server.js` only makes it prompt. Every
list/read additionally applies `withActiveExpiryFilter`, and requester/admin
active lists also exclude rows already marked expired, so a stale row can never
be displayed as active. An accept that races the sweep either wins or receives
the existing “already cancelled” business error.

## 3. Privacy, RBAC and the ADMIN log deletion contract

* `domain/privacy.js` **omits** (never blanks) `email`/`phone` for every
  non-ADMIN viewer across the responder directory, request payloads
  (`acceptedBy`, `assignments[].responder`, `allocations[].responder`) and
  realtime events. Requesters keep their own contact details.
* Roles always come from PostgreSQL: `authMiddleware` re-reads the user row and
  ignores role claims in the token.
* `DELETE /api/admin/logs/:id` requires ADMIN, `{confirm:true}`, and a *closed*
  request. It archives (`archivedAt`/`archivedById`) instead of destroying, and
  writes a separate `ADMIN_DELETED_LOG` audit entry with
  `preservedSecurityAudit: true`. `GET /api/admin/audit-logs` is read-only;
  no endpoint deletes audit rows.
* Credential endpoints are rate limited (`authLimiter`, `googleAuthLimiter`,
  `passwordResetLimiter`, `emailResendLimiter`, `adminSensitiveLimiter`) while
  emergency traffic (request creation, GPS, heartbeat, socket) is explicitly
  excluded.

## 4. Authentication additions

* `POST /api/auth/google` verifies a Firebase ID token against Google’s
  published certificates (RS256, `kid` rotation, 1-hour cache, injectable
  `fetch` for tests), then: known `firebaseUid` → login; verified email →
  link to the existing active ERAS account without changing its role; otherwise
  create with a random bcrypt password and `authProvider: GOOGLE`. Public
  registration accepts only `REQUESTER` and `RESPONDER`
  (`PUBLIC_REGISTRATION_ROLES`); ADMIN can never be created from a client
  payload.
* While unconfigured the endpoint answers
  `503 Google sign-in is not configured on this server`, and the client shows
  that message verbatim instead of pretending to have signed in.
* Verification and reset codes are crypto-random 6 digits
  (`crypto.randomInt`), stored only as bcrypt hashes, single-use, attempt- and
  rate-limited, with a resend cooldown, a 10-minute reset TTL / 30-minute
  verification TTL, and needless-log-safe email delivery (codes are never
  logged). Password reset sets `passwordChangedAt`, which invalidates sessions
  issued earlier.

## 5. Commands that ran, with results

Run in GitHub Actions (the platform the repository already uses):

| Command | Result |
| --- | --- |
| `npm ci && npx prisma generate && npx prisma migrate deploy && node scripts/verify-schema.js` | success (PostgreSQL 16 service container) |
| `npm audit --omit=dev --audit-level=high` | success, 0 vulnerabilities |
| `npm test -- --runInBand` | **480 tests pass**, 0 failures (49 suites) |
| `flutter pub get` | success |
| `dart format --output=none --set-exit-if-changed .` | success (no diff) |
| `flutter analyze` | **No issues found!** |
| `flutter test` | **+301 … All tests passed!** |
| `flutter build web --release --dart-define=ERAS_API_BASE_URL=https://eras-api-sdjo.onrender.com` | success → `build/web` |
| `flutter build apk --release --dart-define=ERAS_API_BASE_URL=https://eras-api-sdjo.onrender.com` | success → `app-release.apk` (57.8 MB), no `google-services.json` present |
| `npm audit` (full tree) in the sandbox | `found 0 vulnerabilities` |

Both repository workflows are green on the final commit `921bef4`
(Backend run 36970921940, Flutter run 36970921995). `.github/workflows/dart.yml`
is untouched; the two temporary diagnostic workflows used to read the runner’s
output were deleted before the final commit.

## 6. Hardening audit — what was checked and what changed

* **SQL injection:** no raw SQL with interpolation exists; the only `$queryRaw`
  uses are tagged templates with `FOR UPDATE` row locks and bound parameters.
  No `unsafe()`.
* **Mass assignment:** every update path names its fields;
  `tests/security/massAssignmentAudit.test.js` scans the source for raw
  `...req.body` spreads, protected fields taken from the request, and role
  writers (only the two allow-listed auth paths, both with an explicit role
  allow-list).
* **Validation:** allow-listed type/length/range/enum checks with explicit
  maxima (emergency type ≤80, location ≤300, description ≤2000, resource name
  ≤120, quantity ≤1,000,000, id-token ≤8192, code `^\d{6}$`, password 6–128).
* **XSS:** the Flutter client renders text only (no `HtmlElementView`, no
  `WebView`, no HTML string building); `web/index.html` has no `innerHTML`,
  `document.write` or `eval`. The API’s CSP is `default-src 'none'` and gains
  Firebase/Google Identity/Google Maps/Socket.IO origins only when the API
  serves the Flutter web bundle (`SERVE_FLUTTER_WEB_FROM_API`).
* **File upload:** the application has no upload feature, so no upload
  hardening was added; nothing in the codebase accepts multipart data.
* **Passwords:** bcrypt (cost 10) everywhere — no MD5/SHA-1/plaintext, no
  plaintext comparison, and no migration to a new scheme was needed or made.
* **Sessions:** bearer JWT kept (no cookie conversion), `passwordChangedAt`
  revocation, identity/role re-read from the database, `JWT_SECRET` from the
  environment only. CSRF: the decision is *not applicable* to this architecture
  (no cookies, no browser-authenticated ambient credentials) and is documented
  in code; no CSRF token machinery was added that would misrepresent the
  threat model.
* **Transport/headers:** CORS is an explicit allow-list (no `*`), the JSON body
  limit is enforced with a 429 `rate_limit.exceeded` response, and
  `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy`,
  `Permissions-Policy`, `Cache-Control: no-store` and production-only HSTS are
  set.
* **Errors/logging:** error responses carry no stack traces or internals;
  audit events are recorded without secrets; the logger never prints codes,
  tokens or connection strings. `npm audit` is clean; no dependency was
  upgraded in a way that changes runtime behaviour.

## 7. Frontend changes worth calling out

* `ErasClock`/`formatErasClock` render a zero-padded 24-hour `HH:MM:SS` value
  and own their 1-second timer, so the console no longer rebuilds every second.
* The resource editor dialog now decides its field layout from the viewport
  and the readiness inventory row switches to a stacked layout under 460 px, so
  “Total quantity” can no longer collide with “No responder inventory
  assigned”. (`LayoutBuilder` is deliberately *not* used inside the dialog:
  `AlertDialog` measures its content with `IntrinsicWidth`.)
* `DirectionsButton` uses the existing ERAS accent with explicit
  hover/pressed/disabled states and white (dark: near-black) foreground text.
* The authenticated dark theme and the centralised theme/motion tokens are
  preserved — `AuthMotion` gained the `fast`/`normal` durations and `outCurve`
  easing that ~20 call sites already referenced.
* Registration and password login now lead into the verification step only when
  the server says the mailbox is unverified; the Google path skips it. The
  realtime socket is opened only once a session reaches the authenticated area.

## 8. Database

One migration: `20261001120000_auth_verification_expiry_and_privacy`
(`prisma/migrations`, applied by `prisma migrate deploy` in CI and by the
Render build). It adds the `AuthProvider`/`AuthCodePurpose` enums, the
`User` verification/provider/`firebaseUid`/`passwordChangedAt` columns (with a
backfill marking existing accounts verified), the `EmergencyRequest`
expiry/archival columns plus two indexes, and the `AuthCode`/`AuditLog`
tables. No column was dropped, no `migrate reset`/`dev`/`db push` was run
anywhere, and the migration was exercised against a real PostgreSQL 16 in CI.

## 9. Lifecycle preservation

`PENDING → ACCEPTED → IN PROGRESS → COMPLETED`, multi-responder
accept/start/complete/end-assignment, requester “confirm received”, and the
resource-bearing flow all still pass their original suites
(`tests/dispatch/*`, `tests/lifecycle/*`, `tests/allocation/*`,
`tests/e2e/dispatchWorkflow.e2e.test.js`, plus the Flutter workflow tests).
The legacy Allocate / Dispatch / Mark Delivered controls remain deliberately
unwired on the normal responder board.

## 10. Deployment notes

* Render: `render.yaml` unchanged; `PRODUCTION_DEPLOYMENT.md` now lists the two
  optional Google variables (`FIREBASE_PROJECT_ID`, `GOOGLE_CLIENT_ID`).
  Without them Google sign-in answers 503 and everything else keeps working.
* `frontend/emergency_app/FIREBASE_GOOGLE_SIGNIN_SETUP.md` documents the
  Firebase/Google console steps and the `--dart-define` values for web and APK.
  No secret, key or connection string is committed; `google-services.json` and
  `GoogleService-Info.plist` stay ignored.
* Split-APK strategy and the existing `tool/build_production_web.sh` are
  untouched.

## 11. Not verifiable in this environment (explicit blockers)

1. **Live Google/Firebase exchange.** `www.googleapis.com`,
   `identitytoolkit.googleapis.com` and `accounts.google.com` are unreachable
   from the sandbox (connection 000), and no `google-services.json` /
   `GoogleService-Info.plist` exists here. The token verifier and the account
   resolution are covered by tests with an injected `fetch`, but a real
   end-to-end Google sign-in must be run once on a configured deployment.
2. **Browser-side SDK load.** The Google Identity Services script and the
   sequential Firebase compat loader in `web/index.html` are runtime,
   browser-only dependencies; that path was reasoned about and left harmless,
   but it was not executed in a real browser here.
3. **Google Maps / Photon runtime calls.** `flutter test` never performs real
   network I/O, so map tiles and geocoding were not exercised.
4. **Local toolchain runs.** The sandbox has no Flutter/Dart SDK and cannot
   fetch Prisma engines (`binaries.prisma.sh` blocked), so `flutter analyze`,
   `flutter test`, `dart format` and the DB-backed jest suites could not run
   *here*; the sandbox ran `npm ci`, `npm audit` and the 158 non-database jest
   tests. Every Flutter and database claim in item 5 rests on the CI runs
   listed above, which use the repository’s own workflows.
5. **Production environment.** Nothing was deployed; the Render service,
   Neon database and Firebase project were not touched. The production API
   base URL was only used as a `--dart-define` value during the build checks.

## 12. Known follow-ups (explicitly out of scope of this pass)

* Adding `google-services.json` (Android) and the web Firebase config to the
  release pipeline is a deployment step, not a code change; until then the
  Google button reports the honest “not configured” message.
* `dispatchAllocation` / `markAllocationDelivered` remain reachable from
  `allocation_dialog.dart` for history views; they are intentionally not wired
  into the responder console.
* The Android NDK warning (“Already watching path”) observed during the release
  build is a Gradle/plugin notice, not a build failure.
