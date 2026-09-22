const prisma = require('../config/prisma');

exports.updateResponderStatus = async (userId, status) => {
  return await prisma.user.update({
    where: { id: userId },
    data: {
      responderStatus: status,
      lastActiveAt: new Date()
    }
  });
};

exports.updateResponderLocation = async (userId, location, latitude, longitude) => {
  return await prisma.user.update({
    where: { id: userId },
    data: {
      location,
      latitude,
      longitude,
      lastActiveAt: new Date()
    }
  });
};

exports.getResponders = async () => {
  return await prisma.user.findMany({
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
    orderBy: {
      id: 'asc',
    },
  });
};