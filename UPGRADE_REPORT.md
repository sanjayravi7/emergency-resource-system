# ERAS upgrade report — Phases 1 to 17

Branch: `arena/01a0d522-emergency-resource-system`
Date: 2026-09-24

**Core problem solved:** the requester UI no longer knows anything about
"Ambulance / Blood / Volunteer". Every resource shown, selected, validated and
allocated comes from the `Resource` table in PostgreSQL. A resource an admin
adds at runtime (verified end to end with "Rescue Boat") shows up in the app
with no Flutter change.

---

## 1. Files changed

### Backend — modified

| File | What changed |
|---|---|
| `backend/prisma/schema.prisma` | Added `isActive Boolean @default(true)`, `lowStockThreshold Int @default(1)` and `@@index([isActive])` to `Resource`. **No existing field, model or relation was removed or recreated.** |
| `backend/package.json` | Added `"seed": "node prisma/seed.js"` npm script + `prisma.seed` hook. Re-indented the `scripts` block. |
| `backend/src/services/resourceService.js` | Rewritten around the validator: `getAllResources({ includeInactive })` (active-only by default, ordered by name), `getLowStockResources()`, `createResource`, `updateResource`, `setResourceActive(id, bool)`, `deleteResource`. No duplicate functions added. |
| `backend/src/services/requestService.js` | Added the shared `requestInclude` (requester `{id,name,email,phone}`, `acceptedBy`, `requiredResources.resource`, `allocations.resource/responder`); create-time validation of the whole payload; `getAssignedRequests(responderId)`. **`getCompatibleRequestsForResponder` and `acceptEmergencyRequest` kept their original matching rules and their transaction.** |
| `backend/src/services/allocationService.js` | Kept Serializable + `SELECT … FOR UPDATE`. Added `isRetryableTransactionError` + `runSerializableTransaction` so a serialization failure (`P2034`, `40001`, `40P01`, deadlock) is retried instead of leaking a Postgres error, and the loser of a race receives the real business error (`Not enough available quantity`). Added `getAllocationsByResponder`. |
| `backend/src/services/responderResourceService.js` | Added the shared `responderResourceInclude` (responder + resource detail) and quantity/status validation; ownership checks preserved. |
| `backend/src/controllers/resourceController.js` | `getAllResources` now honours `?includeInactive=true` **for ADMIN only**; added `getLowStockResources`, `deactivateResource`, `restoreResource`. |
| `backend/src/controllers/requestController.js` | Added `getAssignedRequests`; create/accept/cancel now map validation errors to HTTP 400. |
| `backend/src/controllers/responderController.js` | Added `getResponders`; removed a dead duplicate `getAllResources` that referenced an undefined service (bug fix). |
| `backend/src/controllers/adminController.js` | Fixed `getAllRequests` (it computed the rows and never called `res.json`), added `getAllAllocations`, `getAllResponders`. |
| `backend/src/routes/resourceRoutes.js` | Added `GET /low-stock` (declared before `/:id`), `PATCH /:id/deactivate`, `PATCH /:id/restore`. Existing routes untouched. |
| `backend/src/routes/requestRoutes.js` | Added `GET /assigned` (RESPONDER). Existing routes untouched. |
| `backend/src/validators/requestValidator.js` | Was **empty**. Now `validateEmergencyRequestInput` + `normalizeRequiredResources`. |

### Backend — added

| File | Purpose |
|---|---|
| `backend/prisma/migrations/20260924090000_add_resource_active_and_low_stock/migration.sql` | The only new migration (see §2). |
| `backend/prisma/seed.js` | Idempotent `upsert` seed (see §5). |
| `backend/src/validators/resourceValidator.js` | `validateResourceInput` / `normalizeResourceInput` for the admin CRUD. |
| `backend/tests/validators/requestValidator.test.js` | 12 unit tests. |
| `backend/tests/validators/resourceValidator.test.js` | 10 unit tests. |

`backend/src/config/prisma.js` is byte-identical to `main` (a driver-adapter
variant was used only inside this sandbox and has been reverted).

### Frontend — modified

| File | What changed |
|---|---|
| `frontend/emergency_app/lib/main.dart` | **3134 → 25 lines.** All demo state is gone: fake request IDs, the fake matching engine, the hardcoded 3-resource list, the simulated responders and the local dispatch timers. It now only builds `MaterialApp` and opens the login screen. No UI was deleted — every panel moved into `lib/widgets` and is backed by the API. |
| `frontend/emergency_app/lib/Services/api_service.dart` | Rewritten: typed methods for every endpoint the UI uses, bearer-token handling, `currentRole` / `currentUserId` / `currentUserName`, uniform error extraction (`Exception(body.message)`), base URL from `--dart-define=ERAS_API_BASE_URL`. |
| `frontend/emergency_app/test/widget_test.dart` | The old test asserted `Dispatch Board` on the first frame, which the app has not shown since login was introduced. Replaced with two tests covering the login screen and its validation. |

### Frontend — added

| File | Purpose |
|---|---|
| `lib/theme/app_theme.dart` | Colours, mono text style, field decoration, date helpers, `firstWhereOrNull`. |
| `lib/models/eras_models.dart` | `BackendResource`, `BackendResponder`, `BackendResponderResource`, `RequiredResourceLine`, `AllocationLine`, `UserSummary`, `EmergencyRequest` (+ `RequestStatus`, `remainingFor`, `isFullyAllocated`, `canBeCancelledByRequester`), `ConsoleView`/`NavItem`/`navItemsForRole`, district + emergency-type constants, `resourceMetaFor` (icon lookup by **type string**, with a generic fallback — never a source of truth). |
| `lib/screens/login_screen.dart` | Real JWT login. |
| `lib/screens/dispatch_console_page.dart` | The single data layer: role-aware loading, every mutation followed by an explicit reload, 20 s polling refresh, pull-to-refresh, snackbars. |
| `lib/widgets/common_widgets.dart` | Panel, pills, chips, rail, bottom nav, top bars, stats. |
| `lib/widgets/new_request_panel.dart` | DB-driven multi-resource request form. |
| `lib/widgets/board_panel.dart` | Dispatch board (desktop table + mobile cards) with role-based actions. |
| `lib/widgets/allocation_dialog.dart` | Per-resource allocation against the responder's own inventory. |
| `lib/widgets/resource_panels.dart` | Catalog (+ admin CRUD dialog, deactivate/restore, low-stock banner), responder inventory, live responders. |
| `lib/widgets/log_panel.dart` | Completed/cancelled requests from the DB. |
| `lib/widgets/sector_map.dart` | Map now plots **backend** responders and **backend** open requests. |

---

## 2. Migrations created

Exactly one:

```
backend/prisma/migrations/20260924090000_add_resource_active_and_low_stock/migration.sql

ALTER TABLE "Resource" ADD COLUMN "isActive" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "Resource" ADD COLUMN "lowStockThreshold" INTEGER NOT NULL DEFAULT 1;
CREATE INDEX "Resource_isActive_idx" ON "Resource"("isActive");
```

Additive only — existing rows stay active and keep every column.
Apply with `npx prisma migrate deploy` (or `migrate dev`).

---

## 3. API endpoints

### New

| Method | Path | Role | Notes |
|---|---|---|---|
| `GET` | `/api/requests/assigned` | RESPONDER | Emergencies this responder accepted (their active work). |
| `GET` | `/api/resources/low-stock` | ADMIN | `availableQuantity <= lowStockThreshold`, active only. |
| `PATCH` | `/api/resources/:id/deactivate` | ADMIN | Soft delete: `isActive = false`. |
| `PATCH` | `/api/resources/:id/restore` | ADMIN | `isActive = true`. |

### Changed behaviour (same paths)

| Method | Path | Change |
|---|---|---|
| `GET` | `/api/resources` | Returns only **active** resources for REQUESTER/RESPONDER; ADMIN may pass `?includeInactive=true`. Payload now includes `isActive` and `lowStockThreshold`; ordered by name. |
| `POST` | `/api/resources` | Validated/normalised (`availableQuantity` defaults to `totalQuantity`, `available <= total`, non-negative, optional `unit`/`location`/`lowStockThreshold`). |
| `PATCH` | `/api/resources/:id` | Partial updates validated against the stored row. |
| `POST` | `/api/requests` | Accepts `requiredResources: [{resourceId, quantity}, …]`. Rejects (400): empty list, unknown id, inactive resource, duplicate resource, non-positive/non-integer quantity, quantity above catalog availability, missing type/description/location, invalid priority. Response carries the created `RequestResource` rows with their catalog data. |
| `GET` | `/api/requests/my`, `/compatible`, `/`, `/api/admin/requests` | All use the same include: requester `{id,name,email,phone}`, `acceptedBy`, `requiredResources[].resource`, `allocations[]`. |
| `GET` | `/api/responders` | Previously unusable (`responderController` had no such handler wired to a real service); now returns the responder roster. |
| `GET` | `/api/responder-resources/my`, `/api/responder-resources` | Rows now include responder (`id,name,email,responderStatus`) and resource (`id,name,type,unit,location,isActive`). |
| `GET` | `/api/admin/requests` | Used to hang forever (no `res.json`). Fixed. |
| `POST` | `/api/allocations` | Unchanged contract; serialization failures are retried internally so the client gets the real business error. |

No route, controller or service function was duplicated; no endpoint was removed.

---

## 4. Tests

### Backend — `npx jest --runInBand`

```
Test Suites: 8 passed, 8 total
Tests:       62 passed, 62 total
Time:        ~2.7 s
```

| Suite | Tests |
|---|---|
| `tests/allocation/allocation.test.js` | 11 |
| `tests/auth/auth.test.js` | 7 |
| `tests/authorization/authorization.test.js` | 10 |
| `tests/emergency/emergency.test.js` | 10 |
| `tests/validators/requestValidator.test.js` | 12 (new) |
| `tests/validators/resourceValidator.test.js` | 10 (new) |
| `tests/responder/responder.test.js` | 1 (pre-existing placeholder) |
| `tests/concurrency/concurrency.test.js` | 1 (pre-existing placeholder) |

**0 failures.** No pre-existing test was weakened or deleted.

### Static checks

* `node --check` on **every** `.js` file under `backend/src` and `backend/prisma` — OK (including `src/services/requestService.js`).
* `npx prisma format` / `npx prisma validate` / `npx prisma migrate` — **could not run in this sandbox**: `binaries.prisma.sh` is TLS-blocked, so the Prisma *schema engine* binary can never be downloaded here. The schema was hand-formatted to Prisma style and the migration SQL was applied and exercised directly against PostgreSQL (all 62 tests plus the 46 end-to-end checks below run against that live schema, which proves the schema and client work). `npx prisma generate` **did** run (WASM client).
* `flutter analyze` — **not run: no Flutter/Dart SDK is installable in this sandbox** (`storage.googleapis.com` is blocked). See §7.

### End-to-end run against a live server + live PostgreSQL

Server: `node src/server.js` on port 5000, real JWTs, real Postgres.
**46 checks, 46 passed, 0 failed.** Highlights (actual output):

```
PASS  1. requester login
PASS  2. GET /resources returns the full DB catalog — Ambulance, Blood, Fire Resource, Oxygen, Volunteer (+ others)
PASS  2b. catalog carries isActive + lowStockThreshold
PASS  3. Fire Resource found by TYPE (no hardcoded id) — id=20
PASS  4. POST /requests creates a multi-resource request (Fire x2 + Oxygen x3)
PASS  5. PostgreSQL holds status=PENDING and both RequestResource rows
PASS  6. responder login
PASS  7. responder sees the request in /requests/compatible
PASS  7b. payload carries requester {id,name,email,phone}
PASS  8. responder accepts the request
PASS  8b. DB: ACCEPTED + acceptedById=53 + acceptedAt + responderStatus=BUSY
PASS  9. request disappears from the compatible list
PASS  9b. request appears in /requests/assigned
PASS  10. requester dashboard shows ACCEPTED + assigned responder
PASS  12. allocation created; inventory 6 -> 4; status PARTIALLY_ALLOCATED
PASS  13. over-allocation rejected
PASS  14. create rejected: qty 0 / negative / duplicate / unknown id / empty list / over availability / missing fields
PASS  15. admin creates "Rescue Boat" -> requester sees it with no Flutter change
PASS  16. deactivate hides it and blocks new requests; restore brings it back
PASS  17. role guards (403) for every cross-role attempt
PASS  18. requester cancels a PENDING request; accepted request can no longer be cancelled
PASS  19. allocation cancelled -> responder inventory restored
```

The script is `/home/user/pgtmp/e2e.js` (sandbox-only, deliberately not committed).

---

## 5. Seed

`backend/prisma/seed.js` (`npm run seed`) — idempotent, `upsert` by unique
`name`, resources looked up by type/name, **no hardcoded resource id**:

| Resource | Type | Qty | Unit |
|---|---|---|---|
| Ambulance | AMBULANCE | 10/10 | vehicle |
| Blood | BLOOD | 10/10 | unit |
| Oxygen | OXYGEN | 20/20 | cylinder |
| Fire Resource | FIRE | 10/10 | unit |
| Volunteer | VOLUNTEER | 10/10 | person |

Plus three accounts (password `Test@12345`): `requester@eras.dev`,
`admin@eras.dev`, `responder49@eras.dev` (RESPONDER, `isActive`, `AVAILABLE`)
with a matching `ResponderResource` row per resource, so the responder is
compatible with any of the five out of the box.

---

## 6. Phase checklist

| Phase | Status |
|---|---|
| 1 Dynamic resource selector | Done — `GET /api/resources`, real ids, availability line, out-of-stock shown but unselectable. |
| 2 Multiple resources per emergency | Done — add/remove rows, duplicate/qty/availability blocked client- and server-side. |
| 3 Resource model | Done — `isActive`, `lowStockThreshold` + migration; nothing removed. |
| 4 ResponderResource semantics | Done — capability rows surfaced with responder/resource/total/available/status; accept rules untouched. |
| 5 Accept transaction | Unchanged and verified (ACCEPTED, `acceptedById`, `acceptedAt`, `BUSY`). |
| 6 Requester details in the API | Done and verified in the compatible payload. |
| 7 Dispatch board columns | Done — ID, requester, emergency, location, priority, resources, qty, created, status, action. |
| 8 Requester dashboard | Done — real status, responder, acceptedAt, allocated vs remaining, cancel only when PENDING. |
| 9 Allocation | Preserved + hardened with a retry on serialization failure. |
| 10 Admin CRUD | Done — create/edit/deactivate/restore/low-stock; requester read-only active. |
| 11 DB-driven UI | Done — proved with "Rescue Boat". |
| 12 Validation | Done — both layers. |
| 13 Demo logic removed | Done — `main.dart` 3134 → 25 lines, UI kept, state API-backed. |
| 14 Reload after mutations | Done — plus a 20 s poll; a Socket.IO listener only has to call the same `loadRequests()` / `loadResources()` methods. |
| 15 Seed | Done. |
| 16 File verification | Done (see §1). |
| 17 Checks + manual flow | `node --check` ✅, `npm test` ✅, end-to-end ✅, `prisma format` / `flutter analyze` blocked by the sandbox (see §7). |

---

## 7. Remaining issues / things to do on your machine

1. **`flutter analyze` was never run.** No Dart SDK can be installed here. As a
   substitute every Dart file passed a bracket/string structural parse and a
   scripted cross-check that every constructor call site matches its
   declaration (named args, required args, no stray positionals), plus a manual
   import/symbol review. Still, please run:
   ```
   cd frontend/emergency_app
   flutter pub get
   flutter analyze
   flutter test
   ```
   Expect at most lint-level nits (ordering/`prefer_const`), not compile errors.
2. **`npx prisma format` / `prisma validate` / `prisma migrate dev` were not run**
   (schema-engine binary is not downloadable here). Run
   `npx prisma migrate deploy && npx prisma generate` once before starting the
   server; the SQL in the new migration is already proven against a live DB.
3. **Set the API base URL for real devices.** Default is
   `http://localhost:5000/api`. On Android emulator/physical devices run with
   `flutter run --dart-define=ERAS_API_BASE_URL=http://<host-ip>:5000/api`.
   (The project has no `android/`/`ios/` folder — only `web/` — so `flutter create .`
   may be needed for a mobile build.)
4. **Some service errors still surface as HTTP 500** (`Only PENDING requests can
   be cancelled`, `Not enough available quantity`, …). The existing test suites
   assert 500 for these, so the status codes were deliberately left alone; the
   UI shows the message either way. Changing them means updating those tests.
5. **Socket.IO is still unused.** It stays a dependency; the refresh path is
   polling + explicit reload. Wiring push later means calling the existing
   `loadRequests()` / `loadResources()` from a socket event — no rewrite.
6. **Responder self-service inventory editing** (`POST/PATCH/DELETE
   /api/responder-resources`) exists on the backend but the Flutter UI only
   *displays* the responder's inventory; add a form later if you want it.
7. **`backend/emergency-resource-allocation/backend/**`** is an older duplicate
   copy of the backend that is still in the repo. It was left untouched — it is
   not mounted by `src/app.js` and is safe to delete separately.
8. `frontend/emergency_app/errors.txt` and `errors_lib.txt` are stale analyzer
   dumps from before this work; they are unrelated to the current code.
