const prisma = require('../config/prisma');
const requestService = require('../services/requestService');

exports.endAssignment = async (req, res, next) => {
  try {
    const request = await requestService.endResponderAssignment(
      req.user, req.params.id, req.params.responderId
    );
    res.json({ success: true, request });
  } catch (error) {
    next(error);
  }
};

exports.updateRequestStatus = async (req, res, next) => {
  try {
    const request = await requestService.updateRequestStatus(req.params.id, req.body.status);
    res.json({ success: true, request });
  } catch (error) {
    next(error);
  }
};

exports.getAllUsers = async (req, res, next) => {
  try {
    const users = await prisma.user.findMany({
      select: { id: true, name: true, email: true, phone: true, role: true,
        isActive: true, lastActiveAt: true, responderStatus: true, createdAt: true,
        updatedAt: true },
    });
    res.json({ success: true, users });
  } catch (error) {
    next(error);
  }
};

exports.updateUserRole = async (req, res, next) => {
  try {
    const allowedRoles = ['REQUESTER', 'RESPONDER', 'ADMIN'];
    if (!allowedRoles.includes(req.body.role)) {
      return res.status(400).json({ success: false, message: 'Invalid role' });
    }
    if (Number(req.params.id) === req.user.userId && req.body.role !== 'ADMIN') {
      return res.status(400).json({ success: false, message: 'You cannot demote your own admin account' });
    }
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
    // Reuse the operational request contract instead of maintaining a second,
    // incomplete admin payload. This includes assignments, allocations,
    // required resources, responder locations, and lead metadata exactly as
    // requester/responder REST reconciliation receives them.
    const requests = await requestService.getAllRequests();
    res.json({ success: true, requests });
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