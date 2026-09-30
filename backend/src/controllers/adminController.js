const prisma = require('../config/prisma');
const requestService = require('../services/requestService');

exports.createRequest = async (req, res, next) => {
  try {
    const request = await requestService.createEmergencyRequest(req.user.id, req.body);
    res.status(201).json({ success: true, request });
  } catch (error) { next(error); }
};

exports.assignRequest = async (req, res, next) => {
  try {
    const request = await requestService.acceptEmergencyRequest(req.params.responderId, req.params.id);
    res.json({ success: true, request });
  } catch (error) { res.status(400).json({ success: false, message: error.message }); }
};

exports.cancelRequest = async (req, res, next) => {
  try {
    const existing = await requestService.getRequestById(req.params.id);
    const request = await requestService.cancelEmergencyRequest(existing.requesterId, req.params.id);
    res.json({ success: true, request });
  } catch (error) { next(error); }
};

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
    // The assignment picker needs the same database-backed facts used by the
    // acceptance transaction. Never return the full User row here (in
    // particular, never expose password hashes). `compatibleRequestIds` is
    // computed by the existing compatibility service, so Flutter only offers
    // responders the backend would currently allow to accept.
    const rows = await prisma.user.findMany({
      where: { role: 'RESPONDER' },
      select: {
        id: true,
        name: true,
        email: true,
        phone: true,
        isActive: true,
        responderStatus: true,
        location: true,
        latitude: true,
        longitude: true,
        lastActiveAt: true,
        responderHelpTypes: {
          where: { enabled: true },
          select: { category: true, enabled: true },
          orderBy: { category: 'asc' },
        },
        responderResources: {
          where: { isEnabled: true },
          select: {
            id: true,
            responderId: true,
            resourceId: true,
            totalQuantity: true,
            availableQuantity: true,
            status: true,
            isEnabled: true,
            resource: {
              select: {
                id: true,
                name: true,
                type: true,
                mode: true,
                unit: true,
                location: true,
                isActive: true,
              },
            },
          },
          orderBy: { resourceId: 'asc' },
        },
      },
      orderBy: { name: 'asc' },
    });

    const responders = await Promise.all(
      rows.map(async (row) => {
        const compatibleRequests = row.isActive
          ? await requestService.getCompatibleRequestsForResponder(row.id)
          : [];
        return {
          ...row,
          // Friendly additive aliases keep the Flutter contract concise while
          // preserving the relation-shaped fields for existing consumers.
          helpTypes: row.responderHelpTypes,
          resources: row.responderResources,
          compatibleRequestIds: compatibleRequests.map((request) => request.id),
        };
      })
    );

    res.json({ success: true, responders });
  } catch (error) {
    next(error);
  }
};