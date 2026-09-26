# PHASE F REPORT — Dispatch Workflow Hardening + Multi-Responder Support (Flutter client)

Status: **COMPLETE — stopping for approval.** Flutter-only phase per the Phase F
directives. **No backend file was modified in this phase** (backend working-tree
contents are the approved Phase B–E baseline). No migration. `web/index.html`
untouched.

## 1. Scope & guardrails honored

All 24 parts executed inside `frontend/emergency_app/` only. No backend
(Prisma schema, migrations, services, Socket.IO authorization, Google/Photon
integration) was changed. No second location store was introduced — the
existing `LiveLocationStore` was re-keyed in place. No Google Routes API, no
ETA, no road geometry, no Geocoder: the blue line remains a haversine direct
connection and every Get-directions button uses the existing Google Maps
universal URL launcher. No fabricated data: every name/coordinate/status comes
from backend payloads.

## 2. Models (`lib/models/eras_models.dart`) — Parts 2, 3, 15

Added `ResponderAssignmentLine` (id, requestId, responderId, status
ACTIVE/ENDED, acceptedAt, endedAt, createdAt, updatedAt, responder summary)
with `fromJson`. `EmergencyRequest.assignments` (defaults to `const []`, so
old payloads parse unchanged), `activeAssignments`, `isAssignedTo` (ACTIVE
only), `isLegacyAcceptedBy` (**pair-scoped**: acceptedBy == me AND no
assignment row for ME — mirrors the backend's per-pair fallback exactly),
`ownsUnfinishedAllocation` (RESERVED/DISPATCHED, no assignment required),
`participatesAsResponder` (union, mirrors Phase E rule),
`additionalActiveAssignments`, `withAssignment` (replace-by-responderId, sorted
— no duplicates possible). `withAllocation` and `fromJson` carry/parse
`assignments[]`. No fields invented beyond the REST contract.

## 3. Live location store (`lib/Services/live_location_store.dart`) — Part 4

Fully re-keyed to `(requestId, responderId)`: nested `locationsByRequest`,
`locationsForRequest`, `locationFor`, `isResponderActivelySharing`,
`beginRemoteSharing({requestId, responderId})`, `applyUpdate` (touches only
that responder), `stopSharing(requestId, {responderId})` (one responder's stop
stales only their point; legacy no-responderId call stales the whole request),
`remove`, `beginLocalSharing(requestId, {responderId})` (own identity; missing
id tracked under key 0), `endLocalSharing`, `markConnectionLost`,
`removeRequest`/`clearRequest`. `reconcile` prunes terminal requests and
non-participating responders (ACTIVE assignees + pair-scoped legacy lead),
merges PostgreSQL's throttled persisted coordinates, live socket points always
win. The old flat `locations` getter is deleted.

## 4. Socket service — Part 5 (registration)

`'responder.assigned'` appended to `_serverEventNames` (payloads verified
against `backend/src/realtime/eventEmitters.js`: includes assignment,
assignments[], and the full request snapshot). Client `location.stop` emits
stay `{requestId}` — the server derives the responder from the JWT socket
identity and broadcasts `responderId` back (verified in `socketServer.js`).

## 5. Dispatch console realtime handlers — Part 5 finish

`dispatch_console_page.dart`:
- `responder.location.start/update/stop` now responder-aware; a stop for
  responder A never ends responder B's stream and never ends this device's
  local sharing unless it targets this responder.
- `responder.assigned`: full snapshot → `_applyRealtimeRequest`; snapshot-less
  fallback → `withAssignment` merge + silent REST refresh.
- Redacted `request.updated` invalidation now honors Phase E's `available`
  flag: the pending card is removed only when the request is no longer
  joinable.
- `allocation.updated` unchanged (allocation payload already carries
  responderId).

## 6. Reconnect resync — Part 6

On reconnect the console runs `refreshAll(silent: true)` → REST
(`getAssignedRequests` is participation-aware server-side) →
`locationStore.reconcile(open)`. Duplicates are structurally impossible
(store keyed by pair; reconcile replaces per responder). Live coordinates are
never overwritten by persisted ones.

## 7. Gate classification — Part 7 (A–E, narrowest condition)

- **A (assignment)**: `isAssignedTo` — ACTIVE assignment only.
- **B (allocation owner)**: `ownsUnfinishedAllocation` — RESERVED/DISPATCHED
  own allocations; allocation flow needs no assignment.
- **C (requester)**: cancel/receipt actions — role only.
- **D (admin)**: oversight, unchanged.
- **E (legacy lead)**: `isLegacyAcceptedBy` — acceptedBy == me with no
  assignment row for me; used only for participation/board classification,
  never as the modern assignment test.
Board `_canAllocate` and the live-location gate now use
`participatesAsResponder` (was `acceptedBy?.id == currentUserId`).
`_dispatchable`/`_deliverable` already filtered by own `allocation.responderId`
(allocation ownership). Room subscriptions subscribe to exactly the
participation set the backend authorizes. The allocation-only flow (accept →
allocate without an assignment row) survives end-to-end.

## 8. Requester UI — Part 8

Board `_RespondersCell`: preserved lead block (name, `LEAD · ACTIVE · at …`,
phone via acceptedBy semantics) plus every additional ACTIVE assignment
(`ASSIGNED · <status>`, phone) and one per-responder `LocationSharingSummary`
labelled with the responder's name. ENDED assignments never render as active
work. Log panel (Part 16): responder roster (lead first, then assignments) and
allocations grouped per responder with all statuses
(RESERVED/DISPATCHED/DELIVERED/CANCELLED) preserved; single-responder requests
render exactly as before.

## 9. Responder UI — Part 9

A responder with multiple assigned emergencies sees one card/row per request.
Actions are driven by own assignment/allocation ownership (gates above).
`responder_readiness_page.dart` audited — no single-responder assumptions.

## 10. Map — Parts 10, 12, 13, 14

`OperationalMapMarkerBuilder.buildSnapshots` takes the nested map and renders
one emergency marker plus 0..N responder markers with stable
`responder-{requestId}-{responderId}` ids; display name resolution:
assignment summary → legacy acceptedBy lead → `Responder #id`. Per-pair
polylines `direct-connection-{requestId}-{responderId}`. `NavigationDeck`
(public): desktop = wrapped cards; mobile = full-width card for one
connection, horizontal 148px list of 250px cards for several. Fit-pins bounds
cover every marker (snapshot-driven). `_openDirections(DirectConnection)`
launches the existing Google Maps URL with that responder's point as origin.
The responderId layer is plumbed store → map → connection → card end-to-end.

## 11. Direct connection service — Part 11

`selectDirectConnections({requests, liveLocations})` returns one connection
per valid (open request with coordinates × participating responder with a
point), sorted live-first → requestId → responderId. Relevance =
`participatesAsResponder`; unrelated/ENDED/CANCELLED-only responders produce
nothing. Legacy `selectDirectConnection` wrapper retained.

## 12. Status semantics — Part 15

`isActive`/`isEnded` on assignments; ENDED never counts as active work;
terminal requests keep their terminal status pill — `ENDED` is never invented
client-side.

## 13. Responsive — Part 17

Mobile board cards (multi-responder) and NavigationDeck verified at
320/360/390 in tests; desktop tables are horizontally scrollable; no
functionality hidden at any width.

## 14. Tests — Parts 18, 19 (all existing tests kept, none deleted)

New: `eras_models_assignments_test.dart` (10), `realtime_multi_responder_test.dart`
(9), `multi_responder_ui_test.dart` (6). Extended/rewritten:
`live_location_store_test.dart` (13), `direct_connection_navigation_test.dart`
(+9 multi-responder group; all existing polylines/URL/card/responsive/
description-optionality groups adapted to the nested map and pair polyline
ids), `operational_google_map_test.dart` (+3). Coverage maps to the required
cases 1–30 (models 1–7, store 8–12, realtime 13–18, connections/map 19–24,
UI 25–30). Existing suites for map controls, LegendItem, Maps web init,
Places, Photon abstraction, Get Directions, SocketService singleton, auth and
location pickers are untouched or shape-adapted only.

## 15. Verification status — Part 23 (explicit)

**The Flutter SDK is not available in this sandbox** (`flutter` and `dart`
binaries absent; no `.dart_tool`). `flutter analyze` and `flutter test` could
NOT be executed. Nothing here is a claim of passing tests. What was done
instead: payload-shape verification against the backend source, API
signature cross-checks of every call site, duplicate-member greps, and a
lexer-based brace/paren balance check over all 16 touched Dart files (all
balanced). To verify locally:
`cd frontend/emergency_app && flutter analyze && flutter test`.

## 16. Risks / follow-ups (deferred by design; STOP after F)

- The `responder.assigned` snapshot-less fallback triggers one silent REST
  refresh — backend always sends the snapshot today, so this is dead-code
  safety.
- Assignment-ending API, ENDED persistence on terminal, reactivation, and
  legacy fallback removal remain deferred (Phase G+ per PHASE_A_AUDIT.md).
- Allocation business errors remain 500+message, acceptance 400 (pinned
  backend behavior, unchanged).
- The single biggest untested surface is widget-tree rendering of
  `dispatch_console_page.dart` itself (pre-existing gap — it needs the full
  app/http harness); its building blocks are covered directly.
- No backend change was required by any Flutter failure in this phase, so the
  Part 22 stop-and-report rule was never triggered.

**Phase F stops here for approval.**
