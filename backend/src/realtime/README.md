# ERAS real-time transport

The HTTP API remains the only persistence path. REST services complete their
Prisma transaction first; the service then asks `eventEmitters.js` to publish a
fresh PostgreSQL snapshot through the Socket.IO instance created by
`server.js`.

## Events

- `socket.authenticated`: `{ userId, role, timestamp }` confirms the current
  database-derived identity.
- `socket.invalidated`: `{ code, message, timestamp }` is emitted before a
  connected socket is closed because PostgreSQL no longer considers the user
  active/valid.
- `socket.error`: `{ code, message, ... }` reports rejected protected socket
  actions such as forbidden room joins or rate-limited GPS updates.
- `request.created`: `{ requestId, emergencyType, location, latitude,
  longitude, priority, requiredResources, requester, createdAt, request }`.
  It is sent only to the `user:{id}` rooms of compatible active responders,
  plus the creator and admins.
- `request.updated`: `{ requestId, status, acceptedBy, acceptedById,
  acceptedAt, updatedAt, request }` (the `request` snapshot also carries
  `assignments[]`) for the owning requester, every responder with an ACTIVE
  assignment, the request room, and admins. Other responders receive only a
  redacted `{ requestId, status, available, updatedAt }` invalidation so a
  no-longer-joinable card can be removed without exposing requester data.
  `available` now means "still joinable" (non-terminal AND at least one
  required resource with outstanding quantity), not `status === 'PENDING'`:
  under multi-responder dispatch an ACCEPTED/IN_PROGRESS/PARTIALLY_ALLOCATED
  request may still have outstanding work. The compatibility endpoint stays
  authoritative for a specific responder.
- `responder.assigned`: `{ requestId, responderId, assignment, assignments,
  request }` is emitted after the acceptance transaction commits. The
  assigned responder receives their own assignment confirmation through
  `user:{responderId}`; the request room, the requester, and admins receive
  the full multi-responder assignment state.
- `allocation.updated`: `{ allocationId, requestId, status, quantity,
  resourceId, responderId, updatedAt, allocation, requestStatus }`, restricted
  to the owning requester, assigned responder/request room, and admins.
- `responder.availability`: `{ responderId, responderStatus,
  currentResponderStatus, timestamp }`.
- `responder.location.start`, `responder.location.update`, and
  `responder.location.stop`: `{ requestId, responderId, latitude,
  longitude, timestamp }` where coordinates are present for update.

Clients may request `request.subscribe`, but membership is checked against
PostgreSQL. A requester can subscribe only to their own request, and a
responder only to a request they participate in: an ACTIVE
`ResponderAssignment`, an unfinished allocation (allocation intentionally
does not require an assignment), or - as a legacy fallback - an
`acceptedById` lead row without any assignment data for that pair. Admin
subscriptions are allowed for operational visibility. On (re)connect a
responder is automatically re-joined to the request rooms of all their
non-terminal participations; requesters are re-joined to their own requests.

Location updates are validated against the authenticated responder's current
assignment and an active request. They are broadcast only through the
authorized request room. High-frequency movement remains a Socket.IO concern;
PostgreSQL stores only the throttled latest coordinate on `User`. The defaults
are configurable with:

- `SOCKET_LOCATION_MAX_UPDATES_PER_WINDOW` (default `10`)
- `SOCKET_LOCATION_RATE_WINDOW_MS` (default `1000`)
- `SOCKET_LOCATION_PERSIST_INTERVAL_MS` (default `10000`)
- `SOCKET_SESSION_REVALIDATE_MS` (default `30000`)

Terminal request snapshots emit a `responder.location.stop` PER participating
responder (lead, ACTIVE assignment holders, and allocation owners - each
event carries that responder's id) and subsequent location updates are
rejected. Multiple responders may stream locations on the same request
independently; every location payload carries `responderId`. Connected sockets periodically re-read the database user
row and also revalidate before protected socket actions, so deactivated users
cannot keep using a previously valid JWT session indefinitely.

## Google Maps frontend integration

The Flutter dashboard renders operational locations with the official
`google_maps_flutter` package. For Flutter Web, `frontend/emergency_app/web/index.html`
loads the Google Maps JavaScript API through a local ignored config file:

1. Copy `frontend/emergency_app/web/google_maps_config.template.js` to
   `frontend/emergency_app/web/google_maps_config.js`.
2. Set `window.ERAS_GOOGLE_MAPS_API_KEY` to a Google Maps Platform key that is
   restricted to the Maps JavaScript API and allowed HTTP referrers.
3. Never commit `google_maps_config.js`, unrestricted keys, or production keys.

Required Google Cloud setup:

- Google Cloud project with billing enabled.
- Maps JavaScript API enabled.
- API key restricted by HTTP referrer. Use local development referrers such as
  `http://localhost:*/*`, `http://127.0.0.1:*/*`, and the Arena preview host
  pattern `https://*-*.e2b.app/*`; production keys should allow only the
  deployed ERAS web origin.

The map consumes the same realtime data described above. Request markers come
only from `EmergencyRequest.latitude` / `EmergencyRequest.longitude`; text-only
locations are listed as unavailable on the map rather than projected to fake
coordinates. Responder markers come only from authorized request-room
`responder.location.update` events (or the throttled last-known responder
coordinate returned during REST reconciliation). Flutter updates marker state by
stable marker id and does not call REST for every GPS point.
