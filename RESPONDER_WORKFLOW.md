# ERAS responder workflow

## Current normal workflow

The responder app is deliberately lifecycle-only:

```text
PENDING -> ACCEPTED -> IN_PROGRESS -> COMPLETED
             accept     start          complete
```

- `PATCH /api/requests/:id/accept` assigns an eligible responder.
- `POST /api/requests/:id/start` is the only way a responder starts work.
- `POST /api/requests/:id/complete` is the only way a responder completes work.

The backend is authoritative for every transition. Flutter never writes a
request lifecycle status directly. `START` and `COMPLETE` require an active
`ResponderAssignment`, an active responder account, and an enabled matching
`ResponderHelpType`. Resource requests and resource-free requests use exactly
the same lifecycle.

Completing a request ends its active assignments atomically, recomputes
responder availability from persisted unfinished work, emits the committed
request update and responder availability update, and stops request-scoped
location sharing when appropriate.

## Resource concepts

- `ResponderHelpType` is eligibility: the emergency categories a responder can
  handle (`FIRE`, `MEDICAL`, `ACCIDENT`, `FLOOD`, `RESCUE`, `OTHER`).
- `ResponderResource` is private inventory: a responder's quantity and enabled
  state for one catalog `Resource`. Responders can edit total quantity,
  available quantity, enabled state, and derived availability through the
  readiness/inventory screen. The API enforces non-negative quantities and
  `availableQuantity <= totalQuantity` and checks row ownership.
- `Resource` is the shared, ADMIN-managed catalog. Requesters see active
  catalog rows while creating a request and may select zero or more rows.
  Catalog availability is informative; zero stock, zero online responders, or
  zero selected resources never prevents request creation.

## Allocation compatibility decision

`Allocation`, `RequestResource`, `ResponderResource`, and their relations are
intentionally retained. Existing allocation records remain available for
history, reporting, migration compatibility, and old data. Allocation routes
also remain deployed for legacy clients and admin/reporting integrations, but
they are **legacy-only and not part of the current Flutter responder UI**.

The current responder UI does not expose an Allocate button, allocation
editor, Dispatch action, Mark Delivered action, requester receipt action, an
End Assignment action, or a resource-by-resource delivery workflow. The
existing assignment-end route remains for administrative/legacy cleanup, but
normal completion is performed through COMPLETE RESPONSE. Legacy allocation
endpoints do not replace START/COMPLETE and should not be added to the normal
responder flow.
