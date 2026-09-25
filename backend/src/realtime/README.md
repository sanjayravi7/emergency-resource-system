# ERAS real-time transport

The HTTP API remains the only persistence path. REST services complete their
Prisma transaction first; the service then asks `eventEmitters.js` to publish a
fresh PostgreSQL snapshot through the Socket.IO instance created by
`server.js`.

## Events

- `request.created`: `{ requestId, emergencyType, location, latitude,
  longitude, priority, requiredResources, requester, createdAt, request }`.
  It is sent only to the `user:{id}` rooms of compatible active responders,
  plus the creator and admins.
- `request.updated`: `{ requestId, status, acceptedBy, acceptedById,
  acceptedAt, updatedAt, request }`.
- `allocation.updated`: `{ allocationId, requestId, status, quantity,
  resourceId, responderId, updatedAt, allocation, requestStatus }`.
- `responder.availability`: `{ responderId, responderStatus,
  currentResponderStatus, timestamp }`.
- `responder.location.start`, `responder.location.update`, and
  `responder.location.stop`: `{ requestId, responderId, latitude,
  longitude, timestamp }` where coordinates are present for update.

`socket.authenticated` confirms the database-derived identity. Clients may
request `request.subscribe`, but membership is checked against PostgreSQL.
A requester can subscribe only to their own request, and a responder only to a
request assigned to them. Admin subscriptions are allowed for operational
visibility.

Location updates are validated against the authenticated responder's current
assignment and an active request. They are broadcast only through the
authorized request room. The latest coordinate is persisted to `User` at most
once every ten seconds; high-frequency movement remains a Socket.IO concern.
Terminal request snapshots emit a location stop event and subsequent location
updates are rejected.
