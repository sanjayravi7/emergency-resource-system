const prisma = require('../config/prisma');
const { authenticateSocket } = require('./socketAuth');
const {
  attachSocketServer,
  emitToRoom,
  rooms,
} = require('./socketEvents');

const activeLocationShares = new Map();
const lastLocationPersistAt = new Map();
const LOCATION_PERSIST_INTERVAL_MS = 10000;

function nowIso() {
  return new Date().toISOString();
}

function asRequestId(value) {
  const requestId = Number(value);
  return Number.isInteger(requestId) && requestId > 0 ? requestId : null;
}

function validCoordinate(value, min, max) {
  const number = Number(value);
  return Number.isFinite(number) && number >= min && number <= max
    ? number
    : null;
}

async function requestForResponder(requestId, responderId, includeClosed = false) {
  return prisma.emergencyRequest.findFirst({
    where: {
      id: requestId,
      acceptedById: responderId,
      ...(includeClosed ? {} : { status: { notIn: ['COMPLETED', 'CANCELLED'] } }),
    },
    select: { id: true, requesterId: true, acceptedById: true, status: true },
  });
}

async function refreshSocketIdentity(socket) {
  const user = await prisma.user.findUnique({
    where: { id: socket.user.id },
    select: {
      id: true,
      name: true,
      role: true,
      isActive: true,
      responderStatus: true,
    },
  });
  if (!user || !user.isActive) return null;
  socket.user = user;
  return user;
}

async function canSubscribe(socket, requestId) {
  const currentUser = await refreshSocketIdentity(socket);
  if (!currentUser) return false;

  const request = await prisma.emergencyRequest.findUnique({
    where: { id: requestId },
    select: { requesterId: true, acceptedById: true },
  });
  if (!request) return false;

  if (socket.user.role === 'ADMIN') return true;
  if (socket.user.role === 'REQUESTER') {
    return request.requesterId === socket.user.id;
  }
  return (
    socket.user.role === 'RESPONDER' &&
    request.acceptedById === socket.user.id
  );
}

async function joinAuthorizedRequest(socket, requestId, ack) {
  const authorized = await canSubscribe(socket, requestId);
  if (!authorized) {
    const error = { code: 'FORBIDDEN', message: 'Not authorized for this request' };
    socket.emit('socket.error', error);
    if (typeof ack === 'function') ack({ ok: false, error });
    return false;
  }

  socket.join(rooms.request(requestId));
  if (typeof ack === 'function') ack({ ok: true, requestId });
  return true;
}

function locationPayload(requestId, socket, latitude, longitude) {
  return {
    requestId,
    responderId: socket.user.id,
    latitude,
    longitude,
    timestamp: nowIso(),
  };
}

function emitLocation(eventName, requestId, payload) {
  // The request room can only contain an authorized requester, the assigned
  // responder, or an authorized admin. It is never a global location stream.
  emitToRoom(eventName, payload, rooms.request(requestId));
}

async function persistLatestLocation(socket, latitude, longitude) {
  const key = socket.user.id;
  const previous = lastLocationPersistAt.get(key) || 0;
  const current = Date.now();
  if (current - previous < LOCATION_PERSIST_INTERVAL_MS) return;

  lastLocationPersistAt.set(key, current);
  try {
    await prisma.user.update({
      where: { id: socket.user.id },
      data: {
        latitude,
        longitude,
        lastActiveAt: new Date(),
      },
    });
  } catch (error) {
    // Live movement remains a Socket.IO concern. A transient persistence
    // failure must not turn a valid location broadcast into a fake failure.
    lastLocationPersistAt.delete(key);
  }
}

function shareKey(socket, requestId) {
  return `${socket.id}:${requestId}`;
}

function bindLocationEvents(socket) {
  socket.on('responder.location.start', async (data = {}, ack) => {
    const currentUser = await refreshSocketIdentity(socket);
    if (!currentUser || currentUser.role !== 'RESPONDER') {
      const error = { code: 'FORBIDDEN', message: 'Only responders can share location' };
      socket.emit('socket.error', error);
      if (typeof ack === 'function') ack({ ok: false, error });
      return;
    }

    const requestId = asRequestId(data.requestId);
    const request = requestId
      ? await requestForResponder(requestId, socket.user.id)
      : null;
    if (!request) {
      const error = {
        code: 'FORBIDDEN',
        message: 'Responder is not assigned to an active emergency',
      };
      socket.emit('socket.error', error);
      if (typeof ack === 'function') ack({ ok: false, error });
      return;
    }

    socket.join(rooms.request(requestId));
    activeLocationShares.set(shareKey(socket, requestId), true);
    const payload = {
      requestId,
      responderId: socket.user.id,
      timestamp: nowIso(),
    };
    emitLocation('responder.location.start', requestId, payload);
    if (typeof ack === 'function') ack({ ok: true, ...payload });
  });

  socket.on('responder.location.update', async (data = {}, ack) => {
    const currentUser = await refreshSocketIdentity(socket);
    if (!currentUser || currentUser.role !== 'RESPONDER') {
      const error = { code: 'FORBIDDEN', message: 'Only responders can share location' };
      socket.emit('socket.error', error);
      if (typeof ack === 'function') ack({ ok: false, error });
      return;
    }

    const requestId = asRequestId(data.requestId);
    const latitude = validCoordinate(data.latitude, -90, 90);
    const longitude = validCoordinate(data.longitude, -180, 180);
    const request = requestId
      ? await requestForResponder(requestId, socket.user.id)
      : null;

    if (!request || latitude === null || longitude === null) {
      const error = {
        code: 'FORBIDDEN',
        message: !request
          ? 'Responder is not assigned to an active emergency'
          : 'A valid latitude and longitude are required',
      };
      socket.emit('socket.error', error);
      if (typeof ack === 'function') ack({ ok: false, error });
      return;
    }

    socket.join(rooms.request(requestId));
    activeLocationShares.set(shareKey(socket, requestId), true);
    const payload = locationPayload(requestId, socket, latitude, longitude);
    emitLocation('responder.location.update', requestId, payload);
    // This is deliberately throttled. PostgreSQL stores the latest useful
    // responder position; it is not used as the high-frequency event log.
    void persistLatestLocation(socket, latitude, longitude);
    if (typeof ack === 'function') ack({ ok: true, ...payload });
  });

  socket.on('responder.location.stop', async (data = {}, ack) => {
    const currentUser = await refreshSocketIdentity(socket);
    if (!currentUser || currentUser.role !== 'RESPONDER') {
      const error = { code: 'FORBIDDEN', message: 'Only responders can share location' };
      socket.emit('socket.error', error);
      if (typeof ack === 'function') ack({ ok: false, error });
      return;
    }

    const requestId = asRequestId(data.requestId);
    const request = requestId
      ? await requestForResponder(requestId, socket.user.id, true)
      : null;
    if (!request) {
      const error = { code: 'FORBIDDEN', message: 'Responder is not assigned to this emergency' };
      socket.emit('socket.error', error);
      if (typeof ack === 'function') ack({ ok: false, error });
      return;
    }

    activeLocationShares.delete(shareKey(socket, requestId));
    emitLocation('responder.location.stop', requestId, {
      requestId,
      responderId: socket.user.id,
      timestamp: nowIso(),
    });
    if (typeof ack === 'function') ack({ ok: true, requestId });
  });
}

function bindSocketConnection(socket) {
  const userRoom = rooms.user(socket.user.id);
  socket.join(userRoom);
  if (socket.user.role === 'RESPONDER') socket.join(rooms.responders);
  if (socket.user.role === 'ADMIN') socket.join(rooms.admins);

  // Join currently authorized request rooms at connect time. This gives a
  // reconnecting client a useful baseline before its REST resynchronization.
  void (async () => {
    let requests = [];
    if (socket.user.role === 'REQUESTER') {
      requests = await prisma.emergencyRequest.findMany({
        where: { requesterId: socket.user.id },
        select: { id: true },
      });
    } else if (socket.user.role === 'RESPONDER') {
      requests = await prisma.emergencyRequest.findMany({
        where: {
          acceptedById: socket.user.id,
          status: { notIn: ['COMPLETED', 'CANCELLED'] },
        },
        select: { id: true },
      });
    } else {
      requests = await prisma.emergencyRequest.findMany({
        where: { status: { notIn: ['COMPLETED', 'CANCELLED'] } },
        select: { id: true },
      });
    }
    for (const request of requests) socket.join(rooms.request(request.id));
  })().catch(() => {});

  socket.emit('socket.authenticated', {
    userId: socket.user.id,
    role: socket.user.role,
    timestamp: nowIso(),
  });

  socket.on('request.subscribe', async (data = {}, ack) => {
    const requestId = asRequestId(data.requestId);
    if (!requestId) {
      const error = { code: 'BAD_REQUEST', message: 'A valid requestId is required' };
      socket.emit('socket.error', error);
      if (typeof ack === 'function') ack({ ok: false, error });
      return;
    }
    await joinAuthorizedRequest(socket, requestId, ack);
  });

  socket.on('request.unsubscribe', (data = {}, ack) => {
    const requestId = asRequestId(data.requestId);
    if (requestId) socket.leave(rooms.request(requestId));
    if (typeof ack === 'function') ack({ ok: true, requestId });
  });

  bindLocationEvents(socket);

  socket.on('disconnect', () => {
    for (const key of activeLocationShares.keys()) {
      if (!key.startsWith(`${socket.id}:`)) continue;
      const requestId = Number(key.split(':')[1]);
      activeLocationShares.delete(key);
      emitLocation('responder.location.stop', requestId, {
        requestId,
        responderId: socket.user.id,
        timestamp: nowIso(),
      });
    }
  });
}

function createSocketServer(httpServer, options = {}) {
  const io = attachSocketServer(httpServer, options);
  io.use(authenticateSocket);
  io.on('connection', bindSocketConnection);
  return io;
}

module.exports = {
  LOCATION_PERSIST_INTERVAL_MS,
  createSocketServer,
  canSubscribe,
  requestForResponder,
};
