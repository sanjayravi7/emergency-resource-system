const prisma = require('../config/prisma');

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

exports.logoutResponder = async (userId) =>
  prisma.user.update({
    where: { id: Number(userId) },
    data: {
      responderStatus: 'OFFLINE',
      lastActiveAt: new Date(),
    },
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
