# Phase H — End-to-End Workflow Audit and Hardening Report

Date: 2026-09-27  
Branch: `arena/01a0e194-emergency-resource-system`  
Scope: Phase H only. Phase I was not started.

## 1. Workflow validated

The audited workflow is:

1. A requester creates an emergency with optional description and precise coordinates.
2. Matching responders discover outstanding work through capability overlap.
3. Responder A accepts first and remains the historical/lead `acceptedById`.
4. Responder B accepts the same still-joinable emergency; assignments contain A and B.
5. Responders allocate Blood x2 (`CONSUMABLE`) and Fire Service x1 (`SERVICE`).
6. Allocations are dispatched and completed either by requester receipt or the responder delivery fallback.
7. A and B publish independent Socket.IO locations; stopping or ending A does not stop B.
8. An ENDED responder becomes AVAILABLE, sees compatible outstanding work, and rejoins through the same assignment row.
9. COMPLETED/CANCELLED transitions end assignments, synchronize availability, clean unfinished allocations where required, stop participant locations, and fan out final snapshots.
10. Reconnect uses authoritative REST snapshots and idempotent assignment/allocation/location merging.

The workflow also covers allocation-only participation. Allocation does not require an assignment, an owner with an unfinished allocation remains authorized, and a cancelled allocation alone does not create participation.

## 2. Backend scenarios

`backend/tests/e2e/dispatchWorkflow.e2e.test.js` contains 13 real-path tests using PostgreSQL, Express HTTP, Prisma transactions, JWT authentication, and real Socket.IO clients:

1. Single-responder creation through requester receipt and completion.
2. Blood x2 + Fire Service x1 compatible discovery and notifications for A/B, with unrelated C excluded.
3. Multi-responder acceptance preserving first `acceptedById`, assignments A+B, allocation fan-out, isolated locations, dispatch, receipts, and completion.
4. Allocation-only participation through dispatch/delivery.
5. End A while B remains ACTIVE/BUSY; only A loses location authorization.
6. ENDED → AVAILABLE → compatible → rejoin using the same assignment row.
7. Requester cancellation: assignments, allocations, inventory, availability, and terminal state.
8. Completion cleanup for an assignment-only third responder.
9. Disconnect, missed events, reconnect, and repeated REST resynchronization without duplicates.
10. Concurrent final receipts with one terminal result and no duplicate rows.
11. Concurrent assignment end/rejoin with one unique assignment row.
12. REST and Socket.IO IDOR/spoofing attempts.
13. Edge/admin/error matrix: missing/null/blank descriptions, invalid coordinates, inactive account, duplicate operations, complete admin payload, admin force-completion/cancellation cleanup, safe logging, and Prisma response sanitization.

## 3. Flutter scenarios

`frontend/emergency_app/test/e2e/phase_h_workflow_test.dart` contains 11 tests through production models, stores, map/navigation selectors, and widgets:

- Backend Blood/Fire snapshot parsing and participant derivation.
- Repeated REST/socket snapshot idempotency.
- Strict malformed location rejection (no fabricated `0,0` marker).
- Per-responder assignment-end reconciliation.
- Terminal REST reconciliation.
- Pair-scoped 0/1/2/3 responder markers and direct connections.
- Directions URI checks through decoded query parameters.
- Join actions for PENDING, ACCEPTED, PARTIALLY_ALLOCATED, and IN_PROGRESS work.
- Historical lead, active assignment, and allocation-only responder rendering.
- Local location/end controls isolated from another responder's stream.
- Requester/responder layouts at 320, 360, 390, and desktop width.

## 4. Defects found and fixed

| Area | Defect | Resolution |
|---|---|---|
| REST authorization | Responder `GET /api/requests` returned every emergency | Scoped it to the deduplicated union of the responder's assigned/allocation work and currently compatible work |
| Admin payload | Admin request listing omitted allocation/location contract fields | Reused the authoritative operational request include/shape |
| Terminal realtime | Lifecycle cleanup changed ACTIVE assignments to ENDED before room selection, omitting additional responders | Captured pre-transition participants and targeted final snapshots/stops explicitly |
| Historical participation | An ended lead could continue receiving private snapshots through unconditional `acceptedById` targeting | Legacy lead fallback now applies only when no assignment row exists; active allocation remains an independent leg |
| Cancelled allocations | Historical cancelled allocations could be treated as terminal participants | CANCELLED allocation rows no longer revive participation |
| Assignment end | Ending an assignment did not stop that responder's stream | Emits an idempotent pair-scoped stop when no unfinished own allocation remains |
| Responder delivery | Responder-side final delivery lacked the full terminal request/stop fan-out | Final status now emits the same terminal request update as requester receipt |
| Admin terminal actions | Force cancellation/completion could strand unfinished allocations/inventory | Both use atomic unfinished-allocation cleanup; CONSUMABLE stock is restored, SERVICE quantity is untouched, assignments end, availability resynchronizes |
| Error boundary | Raw Prisma invocation details could be returned to clients | Prisma errors receive a stable client message and safe class/code logging; expected conflicts log without stacks |
| Flutter discovery | Accept UI only allowed PENDING | Accept is available for every open, outstanding request supplied by compatibility REST |
| Flutter assignment UX | No end-assignment action | Added the existing backend end route to the responder board |
| Flutter sharing UX | Another responder sharing could make this client display “Stop” | Start/stop state now uses this device's authenticated local stream only |
| Flutter participant UX | Historical lead could be labelled ACTIVE; allocation-only owners were absent | Added explicit historical/assignment/allocation labels, responder status, deduplication, and active count |
| Flutter telemetry | Invalid/missing coordinates became `(0,0)` | Added strict coordinate parsing/validation and ignored malformed telemetry |
| Flutter map | Stale points could render after participation ended | Marker and direct-connection selection now independently enforce current participation |
| Flutter resync | Repeated request/assignment/allocation payloads lacked explicit deduplication | Added stable id/responder-keyed merges and authoritative snapshot replacement |
| Responsive UI | Long status/resource rows overflowed narrow cards and multi-responder desktop rows | Added wrapping resource/header layout and content-sized desktop row capacity |

## 5. Files changed

### Backend

- `backend/src/controllers/adminController.js`
- `backend/src/controllers/requestController.js`
- `backend/src/middleware/errorMiddleware.js`
- `backend/src/realtime/eventEmitters.js`
- `backend/src/services/allocationService.js`
- `backend/src/services/requestService.js`
- `backend/tests/e2e/dispatchWorkflow.e2e.test.js`

### Flutter

- `frontend/emergency_app/lib/models/eras_models.dart`
- `frontend/emergency_app/lib/screens/dispatch_console_page.dart`
- `frontend/emergency_app/lib/services/api_service.dart`
- `frontend/emergency_app/lib/services/direct_connection_service.dart`
- `frontend/emergency_app/lib/services/live_location_store.dart`
- `frontend/emergency_app/lib/widgets/board_panel.dart`
- `frontend/emergency_app/lib/widgets/common_widgets.dart`
- `frontend/emergency_app/lib/widgets/operational_google_map.dart`
- `frontend/emergency_app/test/e2e/phase_h_workflow_test.dart`
- `frontend/emergency_app/test/operational_google_map_test.dart`

No Prisma schema or migration file was modified. No resource semantics, Socket.IO room name, Photon API, Places API, location architecture, Google Routes API, road routing, or ETA behavior was introduced or changed.

## 6. Verification results

### Database and Prisma

- `npx prisma generate` — PASS, Prisma Client 6.19.3.
- `npx prisma migrate status` — PASS, all 11 migrations applied; schema up to date.
- `node scripts/verify-schema.js` — PASS (exit 0, no output).

### Backend

Final repeated runs:

- Phase H E2E direct run — PASS, 13/13.
- Backend full suite run 1 — PASS, 23 suites and 237/237 tests, 29.279 s.
- Backend full suite run 2 — PASS, 23 suites and 237/237 tests, 29.443 s.

The Phase H E2E suite therefore passed at least three times on the final backend code: once directly and once inside each final full-suite run.

### Flutter

The sandbox could not bootstrap the Dart SDK because its Google-backed download endpoints were unavailable, so the required commands were executed on GitHub Actions against the pushed branch. Successful run: `36301792033`.

- `flutter clean` — PASS.
- `flutter pub get` — PASS.
- `flutter analyze` — PASS, no analyzer failures.
- Flutter full suite run 1 — PASS, 144/144 tests.
- Flutter full suite run 2 — PASS, 144/144 tests.
- Phase H Flutter E2E run 1 — PASS, 11/11.
- Phase H Flutter E2E run 2 — PASS, 11/11.
- Phase H Flutter E2E run 3 — PASS, 11/11.

The temporary verification workflow, release, asset, and tag were removed after verification.

## 7. Security findings

- Global responder REST disclosure is closed.
- Request rooms and location updates require requester ownership, ACTIVE assignment, unfinished own allocation, or the pair-scoped legacy lead rule.
- ENDED assignment rows override legacy lead fallback instead of silently re-authorizing it.
- Client-supplied socket responder IDs cannot spoof another identity; the authenticated identity is authoritative.
- Unrelated responders do not receive full request/allocation snapshots.
- Cancelled allocation rows do not grant participation.
- Raw Prisma invocation/schema details are not returned to clients.
- Existing HTTP status-code conventions were retained.

## 8. Performance observations

- The real PostgreSQL Phase H E2E suite completes in about 4.5 seconds locally.
- The complete 237-test backend suite completes in about 29–30 seconds per run.
- Compatibility/assigned overview performs two bounded indexed queries and deduplicates by request ID in memory.
- Realtime updates are pair-scoped and deduplicated by room, preventing duplicate fan-out when a socket belongs to several authorized rooms.
- No road-routing, ETA, or external Routes API latency was added.

No formal load or soak test was performed; performance conclusions are limited to integration timing and query/fan-out inspection.

## 9. Remaining risks

- Native-device GPS permission behavior and a real Google Maps platform view are not exercised by headless widget tests; production parsing, selection, state, and responsive surfaces are covered.
- Local Flutter execution remains unavailable in this sandbox because Dart SDK download endpoints are blocked; verification is reproducible through the recorded successful GitHub Actions run.
- The repository's `npm audit` baseline reports three high-severity dependency findings; dependency upgrades were outside Phase H and were not mixed into workflow hardening.
- Expected business conflicts still use the established 500 response convention. They are now safely logged/sanitized, but a future API-versioning phase may choose more specific 4xx mappings.

## 10. Phase boundary

Phase H is complete. Phase I was not started.
