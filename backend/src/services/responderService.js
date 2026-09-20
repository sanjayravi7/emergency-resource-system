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