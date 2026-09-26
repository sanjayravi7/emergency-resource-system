const prisma = require('../config/prisma');
const { runSerializableTransaction } = require('./transactionService');
const {
  syncResponderAvailability,
  ACTIVE_REQUEST_STATUSES,
  UNFINISHED_ALLOCATION_STATUSES,
} = require('./lifecycleService');
const {
  emitResponderAvailability,
  emitRequestUpdated,
} = require('../realtime/eventEmitters');

async function emitAfterCommit(callback) {
  try {
    await callback();
  } catch (error) {
    console.error('Realtime emission failed:', error.message);
  }
}

exports.updateResponderStatus = async (userId, status) => {
  const user = await prisma.user.update({
    where: { id: Number(userId) },
    data: {
      responderStatus: status,
      lastActiveAt: new Date(),
    },
  });
  await emitAfterCommit(() => emitResponderAvailability(user.id));
  return user;
};

exports.updateResponderLocation = async (userId, location, latitude, longitude) => {
  const user = await prisma.user.update({
    where: { id: Number(userId) },
    data: {
      location,
      latitude,
      longitude,
      lastActiveAt: new Date(),
    },
  });

  await emitAfterCommit(async () => {
    const activeRequests = await prisma.emergencyRequest.findMany({
      where: {
        acceptedById: user.id,
        status: { notIn: ['COMPLETED', 'CANCELLED'] },
      },
      select: { id: true },
    });
    for (const request of activeRequests) {
      await emitRequestUpdated(request.id, [user.id]);
    }
  });
  return user;
};

exports.heartbeat = async (userId) => {
  const responder = await prisma.user.findUnique({
    where: { id: Number(userId) },
    select: { id: true, role: true },
  });
  if (!responder || responder.role !== 'RESPONDER') {
    throw new Error('Responder not found');
  }

  return prisma.user.update({
    where: { id: responder.id },
    data: { lastActiveAt: new Date() },
  });
};

// Logging out signals "stop matching me" but must never hide committed work:
// the authoritative helper runs immediately afterwards, so a responder with
// an active emergency or an unfinished (RESERVED/DISPATCHED) allocation is
// correctly reported back as BUSY instead of a misleading OFFLINE.
exports.logoutResponder = async (userId) => {
  const result = await runSerializableTransaction(async (tx) => {
    const numericUserId = Number(userId);
    const responder = await tx.user.findUnique({
      where: { id: numericUserId },
      select: { id: true, role: true },
    });
    if (!responder || responder.role !== 'RESPONDER') {
      throw new Error('Responder not found');
    }

    await tx.user.update({
      where: { id: numericUserId },
      data: {
        responderStatus: 'OFFLINE',
        lastActiveAt: new Date(),
      },
    });

    return syncResponderAvailability(tx, numericUserId);
  });

  await emitAfterCommit(() => emitResponderAvailability(Number(userId)));
  return result;
};

/**
 * Read-only operational workload for one responder, computed in PostgreSQL.
 *
 * The client must never derive "am I busy?" on its own: this returns the
 * persisted `responderStatus` together with the counts that explain it, so the
 * UI can show "BUSY - 2 unfinished allocations" without inventing a second
 * lifecycle model. `responderId` is always the authenticated identity passed by
 * the controller, never a client-supplied value.
 */
exports.getResponderWorkload = async (userId) => {
  const numericUserId = Number(userId);
  const responder = await prisma.user.findUnique({
    where: { id: numericUserId },
    select: { id: true, role: true, isActive: true, responderStatus: true },
  });

  if (!responder || responder.role !== 'RESPONDER' || !responder.isActive) {
    throw new Error('Responder not found');
  }

  const [reserved, dispatched, activeRequests] = await Promise.all([
    prisma.allocation.count({
      where: { responderId: numericUserId, status: 'RESERVED' },
    }),
    prisma.allocation.count({
      where: { responderId: numericUserId, status: 'DISPATCHED' },
    }),
    prisma.emergencyRequest.count({
      where: {
        acceptedById: numericUserId,
        status: { in: ACTIVE_REQUEST_STATUSES },
      },
    }),
  ]);

  return {
    responderId: responder.id,
    responderStatus: responder.responderStatus,
    reservedAllocations: reserved,
    dispatchedAllocations: dispatched,
    unfinishedAllocations: reserved + dispatched,
    activeRequests,
  };
};

exports.UNFINISHED_ALLOCATION_STATUSES = UNFINISHED_ALLOCATION_STATUSES;

exports.getResponders = async () =>
  prisma.user.findMany({
    where: {
      role: 'RESPONDER',
      isActive: true,
    },
    select: {
      id: true,
      name: true,
      email: true,
      phone: true,
      location: true,
      latitude: true,
      longitude: true,
      responderStatus: true,
      lastActiveAt: true,
      isActive: true,
    },
    orderBy: { id: 'asc' },
  });
