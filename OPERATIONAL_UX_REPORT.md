# ERAS — Operational Experience Phase Report

Phase goal: move from "verified realtime protocol" to a more complete
operational experience, **without** rewriting the existing Socket.IO
architecture, without a second lifecycle model in Flutter, and without
removing the 20-second REST polling fallback.

---

## 1. Files changed

### Backend (additive only — no schema, no new models, no migrations)

| File | Change |
| --- | --- |
| `backend/src/services/responderService.js` | New `getResponderWorkload(userId)`: reads `responderStatus` plus the RESERVED / DISPATCHED allocation counts and active-emergency count from PostgreSQL. |
| `backend/src/controllers/responderController.js` | New `getMyAvailability` — identity comes from `req.user.id` (verified JWT) only. |
| `backend/src/routes/responderRoutes.js` | New `GET /api/responders/me/availability` (`authenticate` + `authorizeRoles('RESPONDER')`). |
| `backend/src/realtime/eventEmitters.js` | `responder.availability` now carries the workload counts, but **only** to `user:<responderId>` and `admins`; other responders still get the status-only broadcast (`io.to(responders).except(user room)`). |
| `backend/src/realtime/README.md` | Documents the split payload and the new REST read model. |
| `backend/tests/responder/responderAvailability.test.js` | **New** — REST workload read model (6 tests). |
| `backend/tests/realtime/responderAvailabilityEvent.test.js` | **New** — availability payload/room isolation (3 tests). |

### Flutter

| File | Change |
| --- | --- |
| `lib/Services/socket_service.dart` | `RealtimeStatus { connected, reconnecting, offline }`, deduplicated state publishing, `state`/`status` getters. No socket internals exposed. |
| `lib/state/live_location_store.dart` | **New** — single, testable store for request-scoped live / last-known responder positions (revision counter for targeted repaints). |
| `lib/state/request_lifecycle.dart` | **New** — derives the requester timeline and the valid per-allocation action purely from backend statuses. |
| `lib/models/eras_models.dart` | `ResponderAvailability` (backend read model), `UserSummary.mergeMissingFrom`, `EmergencyRequest.withDetailsFrom`, `EmergencyRequest.withAllocation` (targeted updates). |
| `lib/Services/api_service.dart` | `getMyResponderAvailability()`. |
| `lib/widgets/connection_status.dart` | **New** — `ConnectionStatusPill`, `ConnectionNotice`. |
| `lib/widgets/request_timeline.dart` | **New** — `RequestTimeline`, `AllocationProgressList`. |
| `lib/widgets/responder_status_panel.dart` | **New** — `ResponderAvailabilityCard`, `LocationSharingPanel`. |
| `lib/widgets/board_panel.dart` | `detailed` card layout (timeline + per-allocation actions + "blocked by unfinished work" banner); location buttons moved out to the dedicated panel. |
| `lib/widgets/common_widgets.dart` | `statusIndicator` slot on `DesktopTopBar` and `MobileAppBar`. |
| `lib/widgets/sector_map.dart` | Request-id labels, hollow last-known marker, dashed stale connector, `repaintKey`-based `shouldRepaint`. |
| `lib/screens/dispatch_console_page.dart` | Targeted realtime updates, connection-state handling, location lifecycle, availability read model. |
| `test/live_location_store_test.dart`, `test/request_lifecycle_test.dart`, `test/realtime_ui_state_test.dart`, `test/request_timeline_widget_test.dart` | **New** Flutter tests (see §7). |

The existing Socket.IO architecture (rooms, auth middleware, emitters, event
names) was **not** rewritten — only the availability payload gained fields.

---

## 2. Map improvements

Still the same `SectorMapPainter` / `CustomPaint` architecture:

- Emergency/requester location is plotted from the request's real
  latitude/longitude when present (district fallback unchanged) and is now
  **labelled with the request id** (`DB-201`).
- Responder position is drawn from received coordinates only, per request room.
- **Live vs stale is visually unambiguous**: live = solid filled marker + halo
  + `LIVE` label + solid connector line; last known = hollow outlined marker +
  `LAST KNOWN` label + **dashed** connector.
- `responder.location.update` updates **only that request's marker** (no page
  reload, no full REST refresh).
- `responder.location.stop` converts the marker to last known (it is not
  deleted).
- COMPLETED / CANCELLED removes the marker entirely.
- A live point with no update for 60 s is automatically downgraded to last
  known, so the map can never keep claiming live tracking.
- Connection state is shown on the map panel header, and a
  "Last known position" legend entry was added.
- `shouldRepaint` now compares a `repaintKey` (data revision + location-store
  revision) instead of returning `true` every frame.

---

## 3. Requester UX

- Lifecycle timeline on every request card:
  **PENDING → ACCEPTED → ALLOCATED → DISPATCHED → DELIVERED → COMPLETED**,
  with done / current / upcoming styling; a cancelled request keeps the stages
  it really reached and ends on a terminal `CANCELLED` marker.
- Per allocation: resource name, quantity, responder name and the current
  backend status pill.
- `DISPATCHED` → **Confirm Received** button (calls the existing
  `PATCH /api/allocations/:id/received`).
- `DELIVERED` → **Delivered** marker, no action.
- Live/last-known responder position shown with the update time.
- All of it is derived by `RequestLifecycle` from the request status and the
  allocation statuses the backend already returned — **no second lifecycle
  model, no client-side state machine.**

---

## 4. Responder UX

- `RESERVED` → **Confirm & Dispatch** → `DISPATCHED` → **Mark Delivered** →
  `DELIVERED`, rendered next to the allocation it acts on.
- Allocations belonging to other responders show no action.
- Blocked state is visually obvious: an amber banner
  "N allocations still unfinished. You stay BUSY until every one of them is
  delivered."
- **My availability** card shows the backend status (`AVAILABLE` / `BUSY` /
  `OFFLINE`) with the explanation `"2 unfinished allocations"` /
  `"No unfinished work"` and the reserved / dispatched / active-emergency
  counts — all read from `GET /api/responders/me/availability` and the
  authenticated `responder.availability` event.
- The app **never** sets responder status; `syncResponderAvailability` in
  PostgreSQL remains the only writer.

---

## 5. Connection-state handling

- Three user-facing states only: **CONNECTED / RECONNECTING / OFFLINE**.
  No transport name, socket id, URL or attempt counter is ever shown.
- Indicator is in the desktop top bar, the mobile app bar, the map panel, the
  availability card and the live-location panel.
- A `ConnectionNotice` strip explains the degraded state and offers
  "Refresh now".
- Degraded ⇒ REST fallback keeps working: the 20-second polling timer, the
  manual refresh and pull-to-refresh are untouched.
- On reconnect: `refreshAll(silent: true)` REST reconciliation runs first
  (the store never lets REST downgrade a live point), availability is re-read,
  then realtime resumes; paused location sharing restarts automatically.
- `socket.invalidated` still forces a clean logout.

---

## 6. Location lifecycle

- Explicit **[Start Live Location] / [Stop Live Location]** per assigned open
  emergency in the dedicated panel, with `SHARING` badge, coordinates, last
  update time and connection state.
- GPS streams **only** after an explicit start, and only for an emergency that
  is open and assigned to the signed-in responder.
- Auto-stop: request COMPLETED/CANCELLED (local + `request.updated` snapshot),
  `responder.location.stop` from the server, logout, page dispose.
- Transport loss pauses the GPS stream (nothing is streamed into a dead
  socket), marks all points last known, and resumes on reconnect only if the
  request is still open and still assigned.
- Manual stop emits `responder.location.stop` and converts the marker to last
  known.

---

## 7. Tests added

Backend (9 new tests, no existing test weakened):

- `tests/responder/responderAvailability.test.js` — AVAILABLE with no work;
  RESERVED+DISPATCHED counted as unfinished (status BUSY); DELIVERED no longer
  counted; each responder reads only their own workload; requester/admin get
  403; unauthenticated gets 401.
- `tests/realtime/responderAvailabilityEvent.test.js` — workload detail goes to
  the responder's own room + admins; other responders receive the status-only
  payload (`.except(user room)`), with no workload fields; missing responder
  emits nothing.

Flutter (new files; the existing `widget_test.dart` is unchanged):

- `test/live_location_store_test.dart` — targeted per-request marker updates,
  revision bumps, stop → last known, completed/cancelled cleanup, REST
  reconciliation (prune + seed, live never downgraded), staleness expiry,
  transport loss downgrade, logout clear.
- `test/request_lifecycle_test.dart` — stage derivation for every backend
  status, exactly one current stage, cancelled path, requester/responder
  actions, `withAllocation` targeted patch, `withDetailsFrom` contact merge and
  the "unassigned is never back-filled" rule.
- `test/realtime_ui_state_test.dart` — CONNECTED/RECONNECTING/OFFLINE labels
  and degraded flag, signed-out `connect()` is a safe no-op (no duplicate
  listeners), broadcast streams, indicator widgets, availability parsing
  (status-only broadcast must not zero the counts) and the availability card.
- `test/request_timeline_widget_test.dart` — full requester timeline, Confirm
  Received on DISPATCHED, Delivered marker on DELIVERED, responder
  Confirm & Dispatch → Mark Delivered, no action for another responder's
  allocation, and the location-sharing controls (start/stop/paused/closed).

---

## 8. Backend test result

Run in this sandbox against a **real PostgreSQL 18.4** instance:

```
Test Suites: 16 passed, 16 total
Tests:       127 passed, 127 total
```

(previous baseline: 14 suites / 118 tests — nothing regressed, +2 suites /
+9 tests).

Sandbox caveat, stated honestly: `binaries.prisma.sh` is unreachable from this
environment, so the Rust Prisma engines cannot be downloaded and the literal
`npm test -- --runInBand` command fails at Prisma client initialisation here.
The suite above was executed with an equivalent harness: the same Jest config
(`testMatch **/tests/**/*.test.js`, `runInBand`), the same test files, the same
application code, an embedded PostgreSQL 18.4 server with all 9 migrations
applied, and a Prisma client generated with the WASM query compiler +
`@prisma/adapter-pg` (a dev-only `moduleNameMapper` for `src/config/prisma`).
**No application file was modified for this.** On a normal machine with engine
downloads available, `cd backend && npm test -- --runInBand` is the command to
run.

## 9. `flutter analyze` result

**Not run — could not be run in this environment.** There is no Flutter/Dart
SDK in the sandbox and `pub.dev`, `storage.googleapis.com` and
`storage.flutter-io.cn` are all unreachable, so the SDK cannot be installed.
Per your instruction I am not claiming a pass. Please run:

```
cd frontend/emergency_app && flutter analyze
```

## 10. `flutter test` result

**Not run — same reason as §9.** The new tests are written but unexecuted in
this sandbox. Please run:

```
cd frontend/emergency_app && flutter test
```

---

## 11. Remaining limitations

1. **Flutter verification is outstanding.** `flutter analyze` / `flutter test`
   and a two-browser human run have not been executed for this phase.
2. Requester compatibility for responders is still a REST read: a new
   `request.created` triggers one debounced `GET /api/requests/compatible`
   (compatibility is computed in PostgreSQL and cannot be derived client-side).
3. The 20-second polling fallback is intentionally still active, so there is
   still some redundant traffic while the socket is healthy.
4. Realtime request payloads carry a slimmer requester/responder object than
   REST; the client merges the missing contact fields from the previously
   loaded snapshot rather than the backend widening the payload.
5. Live-location staleness uses a fixed 60-second client-side threshold; it is
   not configurable from the backend.
6. Admins see all workload detail through the `admins` room; there is no
   per-admin scoping.
7. The map remains a schematic sector projection (no real tiles/basemap) and
   no route or ETA is drawn.

## 12. Next roadmap recommendation

**Retire the 20-second polling loop safely** — and only then. Concretely:
(a) add a lightweight `GET /api/sync?since=<timestamp>` reconciliation endpoint
so a reconnecting client fetches a delta instead of four full lists;
(b) have the client fall back to polling *only* while the indicator is
RECONNECTING/OFFLINE; (c) add an integration test that kills and restores the
socket mid-flow and asserts the resulting board equals the REST board. That
removes the steady-state redundancy this phase deliberately kept, with a
measurable correctness gate, before any bigger feature (AI allocation, routing,
notifications) is layered on.
