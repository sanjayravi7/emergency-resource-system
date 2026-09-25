const prisma = require('../config/prisma');
const { runSerializableTransaction } = require('./transactionService');
const { syncResponderAvailability } = require('./lifecycleService');
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
