# PHASE F CORRECTION — Flutter multi-responder fixes

Scope: `frontend/emergency_app` only. **No backend file was touched**
(`backend/`, Prisma schema/migrations, Socket.IO server, requestService,
allocationService, lifecycleService are untouched — `git status` shows only
`frontend/emergency_app/**`). Phase G has **not** been started.

---

## 0. Verification environment caveat (read first)

The Arena sandbox this correction was produced in has **no Flutter SDK and no
network access to `storage.googleapis.com` / `pub.dev`** (only `github.com`,
`registry.npmjs.org` and `pypi.org` are reachable). `flutter clean / pub get /
analyze / test` therefore **could not be executed here**; they must be run on
your Windows machine:

```
cd E:\emergency-resource-system\frontend\emergency_app
flutter clean
flutter pub get
flutter analyze
flutter test
```

What *was* done instead of guessing:

* every failing test's fixture was traced by hand against the production
  contract before any production code was touched;
* the participation + `selectDirectConnections` + haversine logic was
  re-implemented 1:1 in a scratch simulation and run against the exact
  fixtures — it reproduces the reported failures with the old fixtures and
  produces the expected `[9, 11]`, `direct-connection-501-9/-11`, `0 m` /
  `7421.7 m`, `11958.6 m` results with the corrected ones;
* all Dart sources were structure-checked (balanced delimiters, string/comment
  aware) after editing.

Windows note: after pulling, if `lib\Services` still appears on disk with the
old three files, delete the stale folder and re-checkout `lib/` — the
canonical folder is now lowercase `lib/services/`.

---

## 1. Files changed

Production (`lib/`)

| File | Change |
| --- | --- |
| `lib/Services/api_service.dart` → `lib/services/api_service.dart` | renamed (canonical lowercase path) |
| `lib/Services/live_location_store.dart` → `lib/services/live_location_store.dart` | renamed + `singleLocationFor` accessor + doc clarification |
| `lib/Services/socket_service.dart` → `lib/services/socket_service.dart` | renamed |
| `lib/models/eras_models.dart` | new `isTerminalRequestPayload(payload)` helper |
| `lib/screens/dispatch_console_page.dart` | imports normalized; terminal cleanup for snapshot-less `request.updated` |
| `lib/services/direct_connection_service.dart` | pair-key (`responderId` = map key) is the responder identity |
| `lib/services/location_service_web.dart` | import normalized (same-directory import) |
| `lib/widgets/operational_google_map.dart` | marker builder keyed by pair key; doc-comment angle brackets; `NavigationDeck` rebuilt (no vertical clipping, horizontal scrolling, `scrollableKey`) |
| `lib/widgets/board_panel.dart`, `common_widgets.dart`, `operational_status.dart`, `screens/login_screen.dart`, `screens/responder_readiness_page.dart` | import path normalization only |

Tests (`test/`) — no test was deleted or weakened

| File | Change |
| --- | --- |
| `test/multi_responder_ui_test.dart` | canonical imports, unused `socket_service` import removed, `responderIsLive` added to the `DirectConnection` fixture (line ~311) |
| `test/direct_connection_navigation_test.dart` | `live()` fixture now **requires** `responderId` (root cause of the responder-11 loss); all call sites made explicit; `502` point keyed to request 502; case 23 taps via `ensureVisible` + real hit-tested `tap`; **two new tests**: scroll-to-and-tap every card (5 responders) and "a navigation card is never clipped by the deck" |
| `test/realtime_multi_responder_test.dart` | payloads now carry real JSON snapshots (`_requestJson`) instead of a parsed model object; mirror handler performs terminal cleanup with the production helper; **three new tests**: 18b per-responder stops vs terminal clear, 18c redacted terminal update, 15b full snapshot REPLACES / incremental row MERGES |
| `test/live_location_store_test.dart` | new test: `singleLocationFor` never guesses a responder |
| `test/nearby_places_test.dart`, `test/requester_location_test.dart` | legacy `locationFor(1)` → explicit `locationFor(1, 9)` (+ `singleLocationFor(1)`) |
| `test/operational_google_map_test.dart`, `test/operational_status_test.dart` | import path normalization only |

---

## 2. Root cause: duplicate `GeoPoint` / `LocationService`

There were **two package URI spellings for one directory**:

* `lib/Services/` (api_service, live_location_store, socket_service) and
* `lib/services/` (location_service, direct_connection_service, …).

On Windows both spellings hit the *same* NTFS folder, so
`package:dispatch_console_flutter/Services/location_service.dart` and
`package:dispatch_console_flutter/services/location_service.dart` resolve to
the same file but are **two distinct Dart libraries**, producing two distinct
`GeoPoint` (and `LocationService`) types — hence
"`GeoPoint` from `lib\Services\…` cannot be assigned to `GeoPoint` from
`lib\services\…`". On Linux/macOS the capitalised import simply does not
resolve at all.

Fix: one canonical convention — lowercase `lib/services/` (Dart/Flutter
convention, and the folder the newer services already used). The three
capitalised files were `git mv`d and **every** import in `lib/` and `test/`
was rewritten. There is now exactly one `LocationService`/`GeoPoint`, one
`SocketService`, one `LiveLocationStore`, one `DirectConnectionService`
library. No casts and no adapter classes were added.

---

## 3. Root cause: responder 11 excluded from direct connections

Production was **not** at fault. The fixture helper in
`direct_connection_navigation_test.dart` was:

```dart
LiveResponderLocation live({int requestId = 501, int responderId = 9, …})
```

and the multi-responder maps were written as

```dart
501: {9: live(...), 11: live(lat…, lng…)}   // 11's point had responderId == 9
```

so the map key said 11 while the point itself said 9. `selectDirectConnections`
used `live.responderId`, so both points were attributed to responder 9 →
one polyline id (`direct-connection-501-9`, deduplicated by the `Set`), the
allocation-only case returned the legacy lead 9 instead of 11, and the
two-request isolation test lost the 501-11 line.

Fixture audit (Phase E participation contract):

| Fixture | Responder 9 | Responder 11 | Responder 12 | Expected |
| --- | --- | --- | --- | --- |
| `assignedRequest` | ACTIVE assignment + acceptedBy lead, live point | ACTIVE assignment, live point | ENDED assignment, no point | connections for 9 and 11 only ✔ |
| allocation-only | acceptedBy lead, no point | RESERVED allocation, no assignment, live point | – | connection for 11 only ✔ |
| CANCELLED allocation | acceptedBy lead, no point | CANCELLED allocation only, live point | – | no connection ✔ |
| two-request | 501 + 502 points | 501 point | – | 3 lines ✔ |

Fixes:

1. `responderId` is now **required** in the `live()` fixture, so key/value can
   never diverge again; every call site states the responder explicitly.
2. Production hardening (no behaviour change, keeps the pair-keyed design
   authoritative): `selectDirectConnections` and
   `OperationalMapMarkerBuilder.buildSnapshots` now iterate `points.entries`
   and take the **map key** as the responder identity — exactly how
   `LiveLocationStore` keys `(requestId, responderId)` state.

Participation itself was already correct and is unchanged: ACTIVE assignment
**or** unfinished (RESERVED/DISPATCHED) allocation **or** pair-scoped legacy
`acceptedBy`. No `acceptedBy`-only filtering was reintroduced; a CANCELLED
allocation and an ENDED assignment still grant nothing.

---

## 4. Root cause: `assignments.length == 1` on `request.updated`

`EmergencyRequest.fromJson` already replaces the whole `assignments[]` array,
and `withAssignment()` only merges one row. The test's payload builder passed
`'request': _requestSnapshot(...)` — which returns a **parsed
`EmergencyRequest` object**, not a JSON `Map`. The handler's
`if (rawRequest is Map)` branch was therefore skipped, the full snapshot was
never applied, and the board kept its seeded single assignment.

Fix: the payloads now carry `_requestJson(...)` (the real Phase E map shape).
New test 15b pins both halves of the contract:

* **A** — a full snapshot with 3 assignments produces `assignments.length == 3`,
  stable order, and a later snapshot with 2 rows *replaces* (not merges);
* **B** — a snapshot-less `responder.assigned` merges exactly one row, keeps
  the existing rows, de-duplicates by `responderId` and stays sorted.

---

## 5. Root cause: terminal location cleanup left both responders

Same fixture defect: the terminal `request.updated` payload carried a model
object instead of a JSON map, so neither `_apply()` nor
`LiveLocationStore.removeRequest()` ever ran and both points survived.

Fixes:

* fixture corrected → the terminal snapshot path runs and
  `removeRequest/clearRequest(42)` drops **every** responder of the request;
* production gap closed: a **redacted** (snapshot-less) `request.updated` that
  reports `COMPLETED`/`CANCELLED` now also stops local sharing and calls
  `locationStore.clearRequest(requestId)`
  (`dispatch_console_page.dart`, using the new shared
  `isTerminalRequestPayload()` helper in `eras_models.dart`);
* per-responder semantics are unchanged and re-pinned by test 18b: one
  `responder.location.stop` only ends that responder's stream (their point
  stays as last-known, the other responder keeps streaming). Only the terminal
  request clears the whole request.

---

## 6. Root cause: "Get directions" hit-test failure

The multi-card deck clipped its own cards:

* mobile: `SizedBox(height: 148)` around a horizontal `ListView` of cards that
  are ~190–260 px tall;
* desktop: `ConstrainedBox(maxHeight: 190)` + vertical `SingleChildScrollView`
  around a `Wrap` of the same cards.

Anything below the clip (the "Get directions" button sits at the bottom of the
card) is painted-out and **not hit-testable**, so `tap()` reported an
off-screen/obscured target and 0 URLs were launched.

Fix (production layout, not the test):

* `NavigationDeck` renders multiple connections as a horizontal
  `SingleChildScrollView` (`key: NavigationDeck.scrollableKey`) containing a
  plain `Row` of `250 px` cards — **no fixed height, no vertical clip**, so
  every card keeps its natural height and every button is fully hit-testable;
  `IntrinsicHeight` is deliberately avoided (`NavigationInfoCard` uses a
  `LayoutBuilder`, which cannot answer intrinsic queries);
* horizontal scrolling keeps narrow viewports overflow-free and large
  responder counts reachable;
* the deck is still the later `Stack` child, so the Google Maps platform view
  can never cover or win the hit test against a card;
* single-connection behaviour (mobile full-width card / desktop compact card)
  and the desktop overlay position are unchanged.

Tests: no `warnIfMissed: false`, no weakened assertions. Case 23 now
`ensureVisible`s then really taps each button; a new test scrolls to and taps
all 5 cards of a 5-responder deck; another new test asserts no card (and no
directions button) is clipped by the deck.

---

## 7. API compatibility fixes

| Contract | Decision |
| --- | --- |
| `DirectConnection(... responderIsLive: …)` | kept required in production; the UI-test fixture now supplies it (live for 9/11, last-known for 12) |
| `LiveLocationStore.locationFor(requestId, responderId)` | **authoritative pair-keyed API, unchanged** |
| legacy `locationFor(1)` call sites | rewritten to `locationFor(1, 9)` — the responder is unambiguous in those two fixtures |
| new `LiveLocationStore.singleLocationFor(requestId)` | clearly named single-location helper: returns the point **only** when exactly one responder is tracked, `null` otherwise — it never returns an arbitrary responder (covered by a new test) |
| `stopSharing(requestId, {responderId})` / `clearRequest` / `removeRequest` | unchanged |
| `isTerminalRequestPayload(payload)` | new shared helper so production and the realtime pipeline test use one terminal rule |

---

## 8. Analyze / lint items addressed

* `unintended_html_in_doc_comment` — `operational_google_map.dart:189`
  now uses backticks: ``` `direct-connection-<request>-<responder>` ```
  (the other `<…>` occurrences live inside a fenced code block and are not
  flagged).
* unused import `package:dispatch_console_flutter/Services/socket_service.dart`
  removed from `test/multi_responder_ui_test.dart` (nothing in that file uses
  `SocketService`).
* all unresolved/duplicated `Services/…` URIs eliminated.
* repo-wide search for `Services/` under `frontend/` now returns nothing.

Target: `flutter analyze` → 0 issues; please confirm on Windows.

---

## 9. Suggested verification run

```
flutter clean
flutter pub get
flutter analyze
flutter test

flutter test test/multi_responder_ui_test.dart
flutter test test/direct_connection_navigation_test.dart
flutter test test/realtime_multi_responder_test.dart
flutter test test/live_location_store_test.dart
flutter test test/eras_models_assignments_test.dart

REM run the multi-responder suites twice
flutter test test/multi_responder_ui_test.dart test/direct_connection_navigation_test.dart test/realtime_multi_responder_test.dart
```

Backend baseline (21/21 suites, 199/199 tests) is untouched — no backend file
was modified.
