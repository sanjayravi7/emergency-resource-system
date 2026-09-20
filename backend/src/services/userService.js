const prisma = require("../config/prisma");

const userSelect = {
  id: true,
  name: true,
  email: true,
  phone: true,
  role: true,
  location: true,
  latitude: true,
  longitude: true,
  isActive: true,
  lastActiveAt: true,
  responderStatus: true,
  createdAt: true,
  updatedAt: true,
};

function getUsers() {
  return prisma.user.findMany({
    orderBy: {
      createdAt: "desc",
    },
    select: userSelect,
  });
}

function updateUserRole(id, role) {
  return prisma.user.update({
    where: {
      id,
    },
    data: {
      role,
      responderStatus: role === "RESPONDER" ? "OFFLINE" : "OFFLINE",
    },
    select: userSelect,
  });
}

function setUserActiveState(id, isActive) {
  return prisma.user.update({
    where: {
      id,
    },
    data: {
      isActive,
      responderStatus: isActive ? undefined : "OFFLINE",
    },
    select: userSelect,
  });
}

module.exports = {
  getUsers,
  updateUserRole,
  setUserActiveState,
};
