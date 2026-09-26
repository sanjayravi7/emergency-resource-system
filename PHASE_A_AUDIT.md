# PHASE A AUDIT — Dispatch Workflow Hardening + Multi-Responder Support

> Status: **AUDIT ONLY — no schema, code, or migration changes have been made.**
> Baseline verified before this audit: **17/17 suites, 130/130 tests passing** (see
> "Environment verification" at the end).

---

## 1. Current architecture relevant to dispatch

### 1.1 Data model (`backend/prisma/schema.prisma`)

| Relationship | Current shape | Multi-responder verdict |
|---|---|---|
| `EmergencyRequest.acceptedById` → `User` | Single nullable FK (`ON DELETE SET NULL`), plus `acceptedAt`. Indexed, **not unique**. | The *only* responder "assignment" record. Holds exactly one responder. |
| `EmergencyRequest` → `Allocation` | One-to-many (`allocations Allocation[]`). No unique constraints on `Allocation` at all (only indexes). | **Already supports** multiple allocations per request and multiple distinct responders per request. |
| `Allocation` → `User` (`responderId`) / `ResponderResource` | FK per allocation; ownership enforced in service layer. | Multiple responders' allocations on one request are representable today. |
| `EmergencyRequest` → `RequestResource` | `@@unique([requestId, resourceId])`, `quantity` = total needed. | Correct for multi-responder: quantity is a per-request target, not per responder. |
| `User` → `ResponderResource` | `@@unique([responderId, resourceId])`; `isEnabled` (durable willingness) + `status` (stock availability) + quantities. | Correct; capability records already support many responders per resource. |
| Responder assignment table | **Does not exist.** | The missing piece. |

**Verdict: no database constraint enforces one responder per emergency.** The
single-responder assumption is entirely in application logic. Conversely, nothing
prevents multiple allocations today — including allocations from responders who
never accepted the request (see §1.3).

### 1.2 Request lifecycle (`RequestStatus`)

`PENDING → ACCEPTED → IN_PROGRESS → PARTIALLY_ALLOCATED → COMPLETED`, with
`CANCELLED` terminal. Status is *derived*, never directly written by clients:

- `lifecycleService.syncRequestStatus(tx, requestId)` recomputes from allocations:
  all required lines fully DELIVERED → `COMPLETED`; any delivered quantity →
  `PARTIALLY_ALLOCATED`; any RESERVED/DISPATCHED → `IN_PROGRESS`; accepted →
  `ACCEPTED` (via `acceptedById`); otherwise `PENDING`. CANCELLED is sticky.
- This function is **already multi-allocation and multi-responder safe** (it sums
  allocations per required resource across all responders).

### 1.3 Acceptance path (`requestService.acceptEmergencyRequest`)

Single Serializable transaction (`runSerializableTransaction` = `Serializable`
isolation + retry on 40001/40P01) with `SELECT … FOR UPDATE` on the request row
and the responder row, then capability rows locked via
`FOR UPDATE OF rr, resource`. Current gates:

1. request must be **PENDING** (hard single-responder gate — the second responder
   gets "Only PENDING requests can be accepted"),
2. responder role/active/`responderStatus === 'AVAILABLE'`,
3. no other active emergency for that responder (via `acceptedById`),
4. responder must satisfy **every** required resource (mode-aware:
   SERVICE needs enabled+active; CONSUMABLE needs status AVAILABLE + quantity),
5. writes `status: 'ACCEPTED'`, `acceptedById`, `acceptedAt`,
6. `syncResponderAvailability` makes the responder BUSY.

### 1.4 Allocation path (`allocationService.createAllocation`)

Serializable transaction locking request → responder resource → required line.
Computes `outstanding = required.quantity − Σ(active allocation quantities)` and
rejects over-allocation. CONSUMABLE: atomic decrement, never negative (row lock +
`availableQuantity < quantity` check), restore on eligible cancellation, never
restore after DELIVERED. SERVICE: no decrement. **This path is already
concurrency-hardened and multi-responder capable** (an existing test
"Concurrent allocations cannot overspend inventory" passes).

**Notable gap:** `createAllocation` does *not* verify the responder is assigned to
the request (no `acceptedById` check). Any capable responder can allocate to any
active request. Existing tests rely on this (e.g. `allocation.test.js`
"✅ RESPONDER can create an allocation" allocates on a PENDING request with no
acceptance; `responderDelivery.test.js` calls the service directly).

### 1.5 Availability (`lifecycleService.syncResponderAvailability`)

Recomputed from persisted work: BUSY if an active emergency exists **via
`acceptedById` only** OR any unfinished (RESERVED/DISPATCHED) allocation exists
(any request — allocation-aware ✓). AVAILABLE only if active + at least one
usable enabled capability (SERVICE enabled+active, CONSUMABLE with stock).
OFFLINE otherwise / via logout (which re-runs the sync so committed work still
shows BUSY). **Half multi-responder aware**: the emergency leg is single-
responder (`acceptedById`), the allocation leg is not.

### 1.6 Realtime (Socket.IO)

- Rooms: `user:{id}`, `request:{id}`, `responders`, `admins` (all preserved).
- Auth: same JWT as REST, identity re-read from PostgreSQL; role never trusted
  from token; periodic session revalidation invalidates inactive users.
- `request.created` → emitted only to *compatible* responders (computed by
  reusing `getCompatibleRequestsForResponder`) + requester + admins.
- `request.updated` → full snapshot to request room + requester + **acceptedById
  user** + admins; redacted invalidation (`available: status === 'PENDING'`) to
  the global `responders` room.
- `allocation.updated` → request room + requester + allocation's responder +
  admins; then a fresh `request.updated`.
- `responder.availability` → user room + responders + admins.
- Live GPS: `responder.location.start/update/stop` — the responder must be
  `acceptedById` of an active request (`requestForResponder`); rate-limited;
  throttled persistence of the latest point.
- Room subscription (`canSubscribe`): ADMIN any; REQUESTER own; RESPONDER only
  `acceptedById === self`. Connect-time auto-join mirrors the same query.
- `responder.location.stop` on terminal status is emitted only for
  `acceptedById`.

### 1.7 REST surface (dispatch-relevant)

| Endpoint | Notes |
|---|---|
| `POST /api/requests` | requester-only; validation incl. optional description (`normalizeOptionalDescription`); compatible-responder fan-out after commit. |
| `GET /api/requests/compatible` | responder; PENDING-only, full-coverage matching, AVAILABLE-only. |
| `GET /api/requests/assigned` | responder; `where acceptedById = me` — **no tests cover it**; Flutter uses it. |
| `GET /api/requests/my` / `GET /api/requests` / `GET /api/admin/requests` | lists; full nested `requestInclude` (requiredResources, requester, acceptedBy, allocations). |
| `PATCH /api/requests/:id/accept` | responder; single-acceptor (§1.3). |
| `PATCH /api/requests/:id/cancel` | requester-owner; transactional inventory restore for RESERVED/DISPATCHED, syncs availability for acceptedById **and** every allocation responder (already multi-responder on the allocation side). |
| `POST /api/allocations`, `PATCH /api/allocations/:id/status`, `PATCH /api/allocations/:id/received`, `GET /api/allocations/my` | see §1.4; ownership enforced; requester receipt confirmation for own requests. |
| `GET /api/requests/:id` | **controller exists but no route is mounted** — not used by Flutter. |

### 1.8 Flutter (frontend/emergency_app)

- `lib/models/eras_models.dart` — `EmergencyRequest` carries a single
  `acceptedBy: UserSummary?` plus `allocations` list; `AllocationLine` has
  `responderId`/`responderName`. No assignment model.
- `lib/Services/api_service.dart` — thin static client; `acceptEmergencyRequest`,
  `getCompatibleRequests`, `getAssignedRequests`, allocations, etc.
- `lib/Services/live_location_store.dart` — **keyed by requestId only**
  (`Map<int, LiveResponderLocation>`), so one responder position per request;
  `reconcile()` reads `request.acceptedBy` (single) for persisted positions.
- `lib/services/direct_connection_service.dart` — `selectDirectConnection`
  returns **one** responder→emergency pair (acceptedBy + live location).
- `lib/widgets/operational_google_map.dart` — marker builder already renders N
  responder markers (by requestId+responderId id) and fit-to-pins for N pins;
  but only **one** direct-connection polyline (`kDirectConnectionPolylineId`)
  and one `NavigationInfoCard`. Blue line is a straight geometric connection,
  explicitly not a route/ETA; "Get directions" uses the key-less universal
  Google Maps URL (no Routes API anywhere).
- `lib/widgets/board_panel.dart` — requester/responder cards;
  `_canAllocate` requires `acceptedBy.id == currentUserId`; shows single
  assigned responder; live location cell per request (single responder).
- `lib/screens/dispatch_console_page.dart` — realtime hub; responder filters
  `request.acceptedBy?.id == currentUserId` for open requests, subscriptions
  (`_syncRequestSubscriptions`), and location-share gating; 20s REST polling
  fallback + reconnect resync (must be preserved).
- `lib/widgets/allocation_dialog.dart` — per-resource allocation UI for the
  assigned responder (multi-allocation capable already).

---

## 2. Exact bottlenecks preventing multi-responder support

**Backend (hard blockers):**
1. `acceptEmergencyRequest` rejects anything not PENDING → a second responder can
   never join; requires full resource coverage instead of "≥1 servable resource".
2. No `ResponderAssignment` relationship — no place to persist multiple
   responders, acceptance timestamps, or membership state; no unique constraint
   to prevent duplicate (request, responder) pairs.
3. `getCompatibleRequestsForResponder`: `status: 'PENDING'` filter and
   `.every(required)` full-coverage match → after first acceptance nobody else
   sees the request; partially-capable responders never see it either.
4. `getAssignedRequestsForResponder` = `acceptedById = me` → additional
   responders see nothing "assigned".
5. `syncResponderAvailability` active-emergency leg reads `acceptedById` only →
   a responder who joined via assignment (future) would be wrongly AVAILABLE.
6. `syncRequestStatus` `ACCEPTED` fallback reads `acceptedById` (fine as legacy
   lead field; must not regress when more responders join).
7. `eventEmitters.requestRooms`/payloads: only requester + acceptedById receive
   room targeting and full snapshots; terminal `responder.location.stop` only
   for acceptedById.
8. `socketServer.canSubscribe` / `requestForResponder` / connect-time join:
   responder authorization is `acceptedById === self` → second responder cannot
   subscribe to the request room or share live GPS.
9. `responderService.updateResponderLocation` fans out only to `acceptedById`
   requests.

**Already multi-responder safe (do not touch):** allocation math
(outstanding/inventory), `syncRequestStatus` per-resource completion rules,
allocation ownership checks, cancel/restore flow, availability's allocation leg,
`getResourceAvailability` SERVICE responder counts.

**Flutter blockers:**
1. `LiveLocationStore` keyed by requestId (one responder position per request);
   `reconcile()` uses single `acceptedBy`.
2. `selectDirectConnection` single pair; map draws one polyline / one nav card.
3. `EmergencyRequest` model has no assignments; `acceptedBy` is the only
   responder notion.
4. Board/console gating on `acceptedBy.id == me` (allocate button, open-request
   filter, subscriptions, location-share start).

---

## 3. Proposed schema changes (Phase B — pending your confirmation)

One new model + two back-relations. **No existing column is removed or altered.**

```prisma
enum AssignmentStatus {
  ACTIVE
  ENDED
}

model ResponderAssignment {
  id          Int             @id @default(autoincrement())
  requestId   Int
  responderId Int
  status      AssignmentStatus @default(ACTIVE)
  acceptedAt  DateTime        @default(now())
  endedAt     DateTime?
  createdAt   DateTime        @default(now())
  updatedAt   DateTime        @updatedAt

  request   EmergencyRequest @relation(fields: [requestId], references: [id], onDelete: Cascade)
  responder User            @relation(fields: [responderId], references: [id])

  @@unique([requestId, responderId])   // duplicate-pair prevention (DB-level)
  @@index([requestId, status])
  @@index([responderId, status])
}
```

- `User.assignments ResponderAssignment[]` and
  `EmergencyRequest.assignments ResponderAssignment[]` back-relations added.
- Migration is purely additive (`CREATE TABLE` + 2 FKs + indexes) — existing
  data untouched; `prisma migrate deploy`-only, no reset.
- `endedAt`/`ENDED` written when the request reaches a terminal state
  (COMPLETED/CANCELLED) inside the same transaction, so "active assignment"
  queries stay a simple indexed lookup.

### `acceptedById` compatibility strategy (required decision — my recommendation)

**Keep it as the "first accepting responder" (lead) field:**
- First acceptance keeps writing `acceptedById`/`acceptedAt` exactly as today →
  every existing test, payload field, and Flutter `acceptedBy` display keeps
  working unchanged.
- Additional responders create only `ResponderAssignment` rows; `acceptedById`
  is never overwritten and never cleared.
- All *authority* (assignment sets, socket authorization, availability,
  assigned-requests) migrates to the assignment table; `acceptedById` becomes
  display/legacy metadata, still surfaced in every response it is today.

### Compatibility semantics change (flagged — needs your sign-off)

Part 3 requires acceptance when the responder has "**at least one** compatible
capability/resource", and Part 6's example (water/oxygen/ambulance across three
responders) requires partial-capability responders to join. Current behavior is
**all-or-nothing** (`.every(required)`), and one existing test asserts that:

- `tests/lifecycle/readinessLifecycle.test.js` — *"3. request requiring Blood +
  Fire does not appear"* (Blood-only responder must NOT see it).

Under the new rule that responder **would** see the request (they can serve the
Blood half; Fire remains outstanding for others). Tests 15–17 (no overlap at all,
zero inventory, inactive resource) remain valid rejections. **Plan:** update
test 3's expectation to the new rule with a comment, add a companion
"no-overlap → incompatible" test, and keep every other assertion intact — total
test count only grows. If you prefer to preserve all-or-nothing *first*
acceptance and only allow partial responders to join *after* the lead accepts,
say so and I'll implement that variant instead (it keeps test 3 byte-identical
but weakens Part 6's scenario where no single responder can cover everything).

---

## 4. Proposed API changes (Phase C/D/E)

Prefer extending existing endpoints; no new URL surface except none required.

1. **`PATCH /api/requests/:id/accept`** (same route, hardened semantics; all
   checks inside one Serializable transaction with row locks, per Part 3):
   - responder exists / active / role RESPONDER / `responderStatus === AVAILABLE`
   - request exists, status ∈ {PENDING, ACCEPTED, IN_PROGRESS, PARTIALLY_ALLOCATED}
     (not CANCELLED/COMPLETED)
   - no duplicate: no existing ACTIVE assignment for (request, responder)
     (unique constraint as backstop → P2002 → clean 409/400)
   - no other ACTIVE assignment/allocation work for this responder on other
     requests (one active emergency per responder — current rule preserved)
   - **≥1 required resource with outstanding quantity > 0** that this responder
     can serve (mode-aware: SERVICE enabled+active; CONSUMABLE AVAILABLE with
     sufficient stock)
   - creates `ResponderAssignment(ACTIVE)`; first accepter additionally sets
     `acceptedById`/`acceptedAt` and status → ACCEPTED (subsequent accepters
     leave status derivation to `syncRequestStatus`)
   - `syncResponderAvailability` in-transaction; realtime emitted after commit
   - response: `{ success, request (with assignments), assignment }` — existing
     `request` key preserved so current Flutter keeps working.
2. **`GET /api/requests/compatible`** — PENDING **+ active** requests; match =
   ≥1 servable resource with outstanding > 0; excludes requests the responder is
   already assigned to; AVAILABLE responders only (unchanged).
3. **`GET /api/requests/assigned`** — requests with an ACTIVE assignment for the
   responder ∪ requests with non-terminal own allocations (covers the legacy
   allocate-without-accept flow so nothing disappears from the board).
4. **All request-list/detail payloads** (`requestInclude` + socket
   `requestPayload`) gain `assignments: [{ id, responderId, status, acceptedAt,
   endedAt, responder: {id, name, phone, responderStatus, …} }]` — additive.
5. **Allocations**: no endpoint changes (already multi-responder safe). I will
   *not* add an "must be assigned" requirement to `createAllocation` because
   existing baseline tests allocate without acceptance; instead the socket layer
   will authorize allocated-but-unassigned responders to subscribe to the
   request room (closes the current gap where their allocations update a room
   they cannot join).
6. **Authorization unchanged**: REQUESTER cannot assign/accept; RESPONDER only
   their own assignments/allocations; ADMIN read oversight. IDOR checks stay in
   services (transaction-internal), not just middleware.

---

## 5. Proposed Socket.IO changes (Phase F)

Preserve all existing rooms and event names. Add **one** new event:

- **`responder.assigned`** → `user:{responderId}` (assignment confirmation),
  `request:{id}`, `user:{requesterId}`, `admins`. Payload: `{ requestId,
  responderId, assignment, request: requestPayload(request) }`.
  This is the "requester sees responders assigned in realtime" + "assigned
  responder gets confirmation" event.

Adjustments (same event names as today):
1. `requestRooms()` — include **all ACTIVE assigned responders** (and responders
   with live allocations) so full snapshots reach everyone entitled.
2. `request.updated` payload — `assignments` included via `requestPayload`;
   redacted `responders`-room invalidation's `available` flag becomes
   "still joinable" (PENDING or has outstanding required quantity) instead of
   `status === 'PENDING'`.
3. `canSubscribe` / `requestForResponder` / connect-time auto-join — responder
   authorization via ACTIVE assignment (or own active allocation), not
   `acceptedById`.
4. Terminal `responder.location.stop` — emitted per assigned responder.
5. `request.created` — mechanics unchanged; compatibility fan-out uses the new
   outstanding-aware matcher (so partially-capable responders get notified,
   already-assigned/unavailable ones don't).
6. `responder.location.*` handlers otherwise unchanged (auth, rate limiting,
   throttled persistence). REST polling fallback + reconnect resync untouched.

---

## 6. Proposed Flutter changes (Phases G–I)

No networking-layer redesign; models keep current naming and null-safety.

1. **`eras_models.dart`**: new `ResponderAssignmentLine` (fromJson defensive,
   same style); `EmergencyRequest.assignments` (default `[]` so old payloads
   still parse); convenience `assignedResponders` (lead first, then others) and
   `isAssignedTo(userId)`; `acceptedBy` retained as the lead responder.
2. **`api_service.dart`**: no new endpoints; accept/assigned/compatible keep
   their signatures (responses simply carry `assignments`).
3. **`live_location_store.dart`**: key positions by `requestId × responderId`
   (composite key map with `locationsFor(requestId)` accessor);
   `reconcile()` seeds last-known positions from **all** assigned responders.
4. **`direct_connection_service.dart`**: `selectDirectConnections` (plural) —
   one direct connection per assigned responder with a live/last-known point;
   existing single selector retained for tests/compat.
5. **`operational_google_map.dart`**: one dashed blue polyline per
   responder→emergency pair (unique `PolylineId` per pair); responder markers
   already multi-capable; `NavigationInfoCard` lists each connection's facts
   (live/last-known, straight-line distance only — never ETA) with per-card
   "Get directions"; fit-to-pins already handles N markers (kept). No Routes
   API, no routing dependency, no fabricated coordinates.
6. **`board_panel.dart`**: requester card shows assigned responders (name,
   phone, status) + allocation responsibilities per responder; responder card
   gates Allocate/Share-location on `request.isAssignedTo(me)` instead of
   `acceptedBy.id == me`.
7. **`dispatch_console_page.dart`**: open-request filter, request-room
   subscriptions, and location-share gating switch to assignment membership;
   handle `responder.assigned` like `request.updated` (same reload path);
   polling fallback and reconnect resync untouched.

**Flutter verification caveat:** the Flutter SDK cannot be installed in this
sandbox (pub.dev / Google storage are unreachable), so `flutter analyze` /
`flutter test` cannot be run here. I will hand-verify against existing patterns
and you must run those two commands on your machine (see Environment section).

---

## 7. Test plan (Phase J)

Baseline to beat: **17/17 suites, 130/130 tests** (re-verified today, see below).

New/extended suites (all real-DB integration tests, same style as existing):

| # | Required case | Where |
|---|---|---|
| 1 | Multiple responders per emergency (assignments persist, both BUSY) | new `tests/dispatch/multiResponder.test.js` |
| 2 | Duplicate responder assignment prevention (sequential + concurrent + DB unique backstop) | same |
| 3 | First responder populates `acceptedById` (compat) | same |
| 4 | Additional responder assignment while ACCEPTED/IN_PROGRESS | same |
| 5 | Incompatible responder rejection (no servable outstanding resource) | same |
| 6 | Unavailable responder rejection (BUSY/inactive/OFFLINE) | same + existing emergency tests unchanged |
| 7 | Multiple allocations across responders/resources on one request | same |
| 8 | Consumable concurrency (final unit, no negative stock, rollback consistency) | `tests/concurrency/concurrency.test.js` (replaces placeholder) |
| 9 | SERVICE resource competition (two AVAILABLE responders, one joins; second blocked by BUSY) | concurrency suite |
| 10 | Cancellation: request cancelled mid-acceptance / mid-allocation; allocation cancelled while another is created | concurrency suite |
| 11 | Completion: 1-of-N delivered → PARTIALLY_ALLOCATED; all delivered → COMPLETED; requester receipt flow; one allocation cancelled → not COMPLETED | lifecycle additions |
| 12 | Availability: BUSY while any assignment/unfinished allocation; AVAILABLE only when all clear; not AVAILABLE just because one allocation delivered | lifecycle additions |
| 13 | Authorization/IDOR: requester can't accept/assign; responder can't touch others' assignments/allocations; admin oversight; socket subscribe isolation | authorization + socketAuthorization additions |
| 14 | Socket.IO assignment events: `responder.assigned` to requester+responder+admins, room isolation, redacted responder invalidation | socketIntegration additions |

Concurrency suite implements Part 7 A–G with **genuine parallelism**
(`Promise.all` of concurrent HTTP/service calls against real PostgreSQL under
Serializable isolation + row locks — the codebase's existing approach; no
sequential fake concurrency).

**Deliberately changed expectation (flagged in §3):** readinessLifecycle test 3
flips to the "at least one servable resource" rule (commented in the test);
companion no-overlap test added. All other 129 assertions must pass unchanged.

---

## Environment verification (this sandbox)

- **Baseline reproduced:** 17/17 suites, **130/130 tests passing** — matches the
  stated regression baseline exactly (incl. the real socketIntegration tests,
  which activate when `DATABASE_URL`/`JWT_SECRET` are present).
- PostgreSQL 17 (embedded binaries) on `127.0.0.1:55432`, all 10 migrations
  applied via `prisma migrate deploy`.
- Because `binaries.prisma.sh` is unreachable here, Prisma runs entirely on its
  bundled **WASM engines**: schema engine via a driver adapter
  (`prisma.config.cjs` outside the repo + a sandbox-only patch for the known
  upstream OID-19 bug, prisma/prisma#27403) and the client engine via a jest
  setup-file shim (also outside the repo). **The repository itself is
  completely untouched** — `git status` clean; your native-engine workflow on
  Windows is unaffected.
- **Flutter SDK is NOT available** (pub.dev / storage.googleapis.com blocked) —
  `flutter analyze` and `flutter test` cannot be executed in this environment
  and must be run on your machine after Phases G–I.

## Risk register

1. Compatibility-semantics decision (§3) — needs your confirmation before Phase B.
2. `GET /requests/compatible` returning active (non-PENDING) requests may
   surprise clients that assume PENDING-only; mitigated by the outstanding-
   resource filter and Flutter updates shipping together.
3. Concurrency tests under Serializable isolation can be flaky on slow CI if
   retry budgets are exceeded; existing `runSerializableTransaction` retry
   (5 attempts, jittered backoff) mitigates.
4. Flutter changes cannot be machine-verified here (see above).
