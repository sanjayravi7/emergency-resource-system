const prisma = require('../config/prisma');
const { runSerializableTransaction } = require('./transactionService');
const { syncResponderAvailability } = require('./lifecycleService');

const VALID_RESPONDER_STATUSES = ['AVAILABLE', 'BUSY', 'OFFLINE'];

exports.updateResponderStatus = async (userId, status) => {
  if (!VALID_RESPONDER_STATUSES.includes(status)) {
    throw new Error('Invalid responder status');
  }

  return runSerializableTransaction(async (tx) => {
    const responder = await tx.user.findUnique({
      where: { id: Number(userId) },
      select: { id: true, role: true },
    });
    if (!responder || responder.role !== 'RESPONDER') {
      throw new Error('Responder not found');
    }

    await tx.user.update({
      where: { id: responder.id },
      data: { lastActiveAt: new Date(), responderStatus: status },
    });

    // The helper remains the source of truth for work-derived status. OFFLINE
    // is an explicit user logout/opt-out and is retained after the sync.
    const synchronized = await syncResponderAvailability(tx, responder.id);
    if (status === 'OFFLINE') {
      return tx.user.update({
        where: { id: responder.id },
        data: { responderStatus: 'OFFLINE' },
      });
    }
    return synchronized;
  });
};

exports.updateResponderLocation = async (userId, location, latitude, longitude) =>
  prisma.user.update({
    where: { id: userId },
    data: {
      location,
      latitude,
      longitude,
      lastActiveAt: new Date(),
    },
  });

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

exports.logoutResponder = async (userId) =>
  runSerializableTransaction(async (tx) => {
    const responder = await tx.user.findUnique({
      where: { id: Number(userId) },
      select: { id: true, role: true },
    });
    if (!responder || responder.role !== 'RESPONDER') {
      throw new Error('Responder not found');
    }

    // Sync before applying the explicit offline state. Active work is never
    // cancelled by logout and therefore remains visible to the lifecycle.
    await syncResponderAvailability(tx, responder.id);
    return tx.user.update({
      where: { id: responder.id },
      data: { responderStatus: 'OFFLINE', lastActiveAt: new Date() },
    });
  });

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
