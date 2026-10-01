# Phase J — One responder workflow for every emergency

Resource-bearing emergencies now follow the same normal responder workflow as
resource-free ones:

```
PENDING → ACCEPTED → IN_PROGRESS → COMPLETED
```

This holds for zero resources, Blood, Oxygen Cylinder, First Aid Kit, Water,
Food Pack, or any other active catalog resource.

## Backend

| Area | Change |
| --- | --- |
| `POST /api/requests/:id/start` | Removed the `Cannot start response on request with required resources` restriction. Start still requires an authenticated, active RESPONDER with an ACTIVE `ResponderAssignment` (or legacy `acceptedById` pair) on a request in `ACCEPTED`. Transition: `ACCEPTED → IN_PROGRESS`. No Allocation rows are required or created. |
| `POST /api/requests/:id/complete` | Removed the `Cannot complete response on request with required resources` restriction. Complete requires the same authorization on a request in `IN_PROGRESS`. Transition: `IN_PROGRESS → COMPLETED`; every ACTIVE assignment ends, responder availability is recomputed, live-location stop + `request:updated` are emitted (existing lifecycle rules, unchanged). |
| `lifecycleService.syncRequestStatus` | A responder-driven `IN_PROGRESS` is never regressed to `ACCEPTED`/`PENDING` by an allocation-derived recompute (e.g. a second responder joining). Legacy delivery may still advance to `PARTIALLY_ALLOCATED`/`COMPLETED`. |
| Acceptance | Unchanged. The existing `findServableRequiredResources` compatibility check (mode-aware, inventory-aware) still gates acceptance of resource-bearing requests. No second algorithm was added. |

### Inventory quantity semantics

Physical CONSUMABLE quantities change **only** through the legacy Allocation
service (reserve / cancel / deliver). The normal workflow never decrements
inventory and never invents hidden Allocation rows; responder inventory is
availability/matching information for acceptance. This is documented in
`requestService.js` next to the start/complete transactions.

### Multi-responder semantics

`COMPLETE RESPONSE` is an explicit terminal action on the emergency by an
assigned responder: it ends every ACTIVE assignment and releases every
responder (same rule the approved resource-free workflow already used). A
responder who wants to leave while others keep working uses
`End Assignment`, which never completes the request.

## Flutter

* `BoardPanel._canStartResponse` / `_canCompleteResponse` no longer require
  `request.requiredResources.isEmpty`.
* The responder "MY ACTIVE EMERGENCY" board wires only
  Accept → START RESPONSE → COMPLETE RESPONSE (+ End Assignment, live
  location). The legacy Allocate / Confirm & Dispatch / Mark Delivered hooks
  are no longer wired there; `BoardPanel` renders them only when a caller
  explicitly passes the legacy callbacks (compatibility only).
* During `IN_PROGRESS` the card shows the `IN PROGRESS` status pill, a
  `Location sharing: ON/OFF` indicator (this device's real sharing state) and
  `COMPLETE RESPONSE`.
* The operational timeline is now `PENDING → ACCEPTED → IN PROGRESS →
  COMPLETED` for every role; legacy allocation rows remain visible as history
  only.
* Requested resources (`Blood × 2`, `First Aid Kit × 1`, …) stay visible on
  the card, in the detail dialog and in after-action history.

## Tests

Backend (`backend/tests/dispatch/resourceBearingWorkflow.test.js`, plus the
updated `resourceFreeWorkflow.test.js` case 10): resource-free and
resource-bearing `ACCEPTED → IN_PROGRESS → COMPLETED`, cannot start an
unaccepted request, cannot complete a request not in progress, unassigned
responder cannot start, start/complete require no Allocation and never touch
inventory, acceptance compatibility still enforced, multi-responder join /
end-assignment / completion semantics, requester history keeps resources.

Flutter (`test/resource_bearing_workflow_ui_test.dart`, updated
`resource_free_workflow_ui_test.dart` and `operational_status_test.dart`):
Start Response visible on a resource-bearing request, Complete Response
visible on a resource-bearing `IN_PROGRESS` request with the location-sharing
indicator, Allocate/Dispatch/Delivered absent from the normal responder
workflow (even with legacy allocation rows), resources listed on the card,
closed state after completion, lifecycle timeline labels.
