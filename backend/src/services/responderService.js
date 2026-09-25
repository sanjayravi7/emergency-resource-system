const prisma = require('../config/prisma');
const { runSerializableTransaction } = require('./transactionService');
const { syncResponderAvailability } = require('./lifecycleService');

exports.updateResponderStatus = async (userId, status) =>
  prisma.user.update({
    where: { id: userId },
    data: {
      responderStatus: status,
      lastActiveAt: new Date(),
    },
  });

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

// Logging out signals "stop matching me" but must never hide committed work:
// the authoritative helper runs immediately afterwards, so a responder with
// an active emergency or an unfinished (RESERVED/DISPATCHED) allocation is
// correctly reported back as BUSY instead of a misleading OFFLINE.
exports.logoutResponder = async (userId) =>
  runSerializableTransaction(async (tx) => {
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
