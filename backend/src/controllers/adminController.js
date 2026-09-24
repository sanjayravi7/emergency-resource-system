const prisma = require('../config/prisma');

exports.getAllUsers = async (req, res, next) => {
  try {
    const users = await prisma.user.findMany();
    res.json({ success: true, users });
  } catch (error) {
    next(error);
  }
};

exports.updateUserRole = async (req, res, next) => {
  try {
    const user = await prisma.user.update({
      where: { id: Number(req.params.id) },
      data: { role: req.body.role }
    });
    res.json({ success: true, user });
  } catch (error) {
    next(error);
  }
};

exports.activateUser = async (req, res, next) => {
  try {
    const user = await prisma.user.update({
      where: { id: Number(req.params.id) },
      data: { isActive: true }
    });
    res.json({ success: true, user });
  } catch (error) {
    next(error);
  }
};

exports.deactivateUser = async (req, res, next) => {
  try {
    const user = await prisma.user.update({
      where: { id: Number(req.params.id) },
      data: { isActive: false }
    });
    res.json({ success: true, user });
  } catch (error) {
    next(error);
  }
};

exports.getAllRequests = async (req, res, next) => {
  try {
    const requests = await prisma.emergencyRequest.findMany({
  where: {
    status: 'PENDING',
  },
  include: {
    requiredResources: true,
    requester: {
      select: {
        id: true,
        name: true,
        email: true,
        phone: true,
      },
    },
  },
  orderBy: [
    { priority: 'desc' },
    { createdAt: 'asc' },
  ],
});
  } catch (error) {
    next(error);
  }
};

exports.getAllAllocations = async (req, res, next) => {
  try {
    const allocations = await prisma.allocation.findMany();
    res.json({ success: true, allocations });
  } catch (error) {
    next(error);
  }
};

exports.getAllResponders = async (req, res, next) => {
  try {
    const responders = await prisma.user.findMany({ where: { role: 'RESPONDER' } });
    res.json({ success: true, responders });
  } catch (error) {
    next(error);
  }
};