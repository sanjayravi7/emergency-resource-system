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
  acceptedAt, updatedAt, request }`.
- `allocation.updated`: `{ allocationId, requestId, status, quantity,
  resourceId, responderId, updatedAt, allocation, requestStatus }`.
- `responder.availability`: `{ responderId, responderStatus,
  currentResponderStatus, timestamp }` for the general broadcast, plus
  `{ reservedAllocations, dispatchedAllocations, unfinishedAllocations,
  activeRequests }` for the responder themselves and for admins. The workload
  detail is emitted only to `user:<responderId>` and `admins`; other
  responders keep receiving the status-only form, so one responder's workload
  never leaks sideways. The same read model is available over REST at
  `GET /api/responders/me/availability` (RESPONDER only, identity taken from
  the JWT - no responderId is accepted from the client).
- `responder.location.start`, `responder.location.update`, and
  `responder.location.stop`: `{ requestId, responderId, latitude,
  longitude, timestamp }` where coordinates are present for update.

Clients may request `request.subscribe`, but membership is checked against
PostgreSQL. A requester can subscribe only to their own request, and a
responder only to a request assigned to them. Admin subscriptions are allowed
for operational visibility.

Location updates are validated against the authenticated responder's current
assignment and an active request. They are broadcast only through the
authorized request room. High-frequency movement remains a Socket.IO concern;
PostgreSQL stores only the throttled latest coordinate on `User`. The defaults
are configurable with:

- `SOCKET_LOCATION_MAX_UPDATES_PER_WINDOW` (default `10`)
- `SOCKET_LOCATION_RATE_WINDOW_MS` (default `1000`)
- `SOCKET_LOCATION_PERSIST_INTERVAL_MS` (default `10000`)
- `SOCKET_SESSION_REVALIDATE_MS` (default `30000`)

Terminal request snapshots emit a location stop event and subsequent location
updates are rejected. Connected sockets periodically re-read the database user
row and also revalidate before protected socket actions, so deactivated users
cannot keep using a previously valid JWT session indefinitely.
