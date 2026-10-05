const prisma = require('../config/prisma');
const requestService = require('../services/requestService');
const auditLogService = require('../services/auditLogService');
const userAdminService = require('../services/userAdminService');

// ADMIN-only identifiers are validated before touching the database so invalid
// or hostile ids cannot reach Prisma as raw input.
function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : null;
}

exports.createRequest = async (req, res, next) => {
  try {
    const request = await requestService.createEmergencyRequest(req.user.id, req.body);
    res.status(201).json({ success: true, request });
  } catch (error) { next(error); }
};

exports.assignRequest = async (req, res, next) => {
  try {
    const requestId = positiveInteger(req.params.id);
    const responderId = positiveInteger(req.params.responderId);
    if (!requestId || !responderId) {
      return res.status(400).json({ success: false, message: 'Invalid request or responder id' });
    }

    const request = await requestService.acceptEmergencyRequest(responderId, requestId, 'ADMIN');
    await auditLogService.recordForRequest(req, 'ADMIN_ASSIGNED_REQUEST', {
      targetType: 'EmergencyRequest',
      targetId: requestId,
      metadata: { responderId },
    });
    res.json({ success: true, request });
  } catch (error) { res.status(400).json({ success: false, message: error.message }); }
};

exports.cancelRequest = async (req, res, next) => {
  try {
    const requestId = positiveInteger(req.params.id);
    if (!requestId) {
      return res.status(400).json({ success: false, message: 'Invalid request id' });
    }

    const existing = await requestService.getRequestById(requestId, 'ADMIN');
    const request = await requestService.cancelEmergencyRequest(existing.requesterId, requestId);
    await auditLogService.recordForRequest(req, 'ADMIN_CANCELLED_REQUEST', {
      targetType: 'EmergencyRequest',
      targetId: requestId,
    });
    res.json({ success: true, request: requestService.projectRequestForViewer(request, 'ADMIN') });
  } catch (error) { next(error); }
};

exports.endAssignment = async (req, res, next) => {
  try {
    const requestId = positiveInteger(req.params.id);
    const responderId = positiveInteger(req.params.responderId);
    if (!requestId || !responderId) {
      return res.status(400).json({ success: false, message: 'Invalid request or responder id' });
    }

    const request = await requestService.endResponderAssignment(
      req.user, requestId, responderId, 'ADMIN'
    );
    await auditLogService.recordForRequest(req, 'ADMIN_ENDED_ASSIGNMENT', {
      targetType: 'EmergencyRequest',
      targetId: requestId,
      metadata: { responderId },
    });
    res.json({ success: true, request });
  } catch (error) {
    next(error);
  }
};

exports.updateRequestStatus = async (req, res, next) => {
  try {
    const requestId = positiveInteger(req.params.id);
    if (!requestId) {
      return res.status(400).json({ success: false, message: 'Invalid request id' });
    }
    // Status is an allow-listed enum value; unknown values are rejected by the
    // service before any write happens.
    const request = await requestService.updateRequestStatus(requestId, req.body && req.body.status);
    await auditLogService.recordForRequest(req, 'ADMIN_UPDATED_REQUEST_STATUS', {
      targetType: 'EmergencyRequest',
      targetId: requestId,
      metadata: { status: req.body && req.body.status },
    });
    res.json({ success: true, request: requestService.projectRequestForViewer(request, 'ADMIN') });
  } catch (error) {
    next(error);
  }
};

/**
 * ADMIN user directory.
 *
 * Every row carries a `history` block with the relationship counters that
 * decide whether the account may be deleted, so an administrator can see
 * *why* an account is removable instead of guessing. Deleting is only offered
 * for an account with `history.deletable === true`.
 */
exports.getAllUsers = async (req, res, next) => {
  try {
    const users = await userAdminService.listUsers();
    res.json({ success: true, users });
  } catch (error) {
    next(error);
  }
};

/**
 * ADMIN correction of another account's display name / phone number.
 *
 * The email address, the role and the active flag are deliberately NOT
 * writable here: each has its own guarded endpoint, and silently rewriting an
 * email address would break login, OTP, password reset and Google linking.
 */
exports.updateUserProfile = async (req, res, next) => {
  try {
    const userId = positiveInteger(req.params.id);
    if (!userId) {
      return res.status(400).json({ success: false, message: 'Invalid user id' });
    }

    const before = await userAdminService.findUserOrFail(userId);
    const user = await userAdminService.updateUserProfile(userId, req.body);

    await auditLogService.recordForRequest(req, 'ADMIN_UPDATED_USER_PROFILE', {
      targetType: 'User',
      targetId: userId,
      metadata: {
        changedFields: Object.keys(req.body || {}),
        previousName: before.name,
        previousPhone: before.phone,
      },
    });
    res.json({ success: true, user });
  } catch (error) {
    if (error instanceof userAdminService.UserAdminError) {
      return res.status(error.statusCode).json({
        success: false,
        code: error.code,
        message: error.message,
      });
    }
    next(error);
  }
};

/**
 * ADMIN removal of an account that carries NO operational history.
 *
 * Requires `{ "confirm": true }`. An account with emergencies, assignments,
 * allocations or responder inventory is refused with 409 and must be
 * DEACTIVATED instead, which preserves history while removing access. The
 * request itself is rate limited by `adminSensitiveLimiter`.
 */
exports.deleteUser = async (req, res, next) => {
  try {
    const userId = positiveInteger(req.params.id);
    if (!userId) {
      return res.status(400).json({ success: false, message: 'Invalid user id' });
    }
    if (req.body && req.body.confirm !== true) {
      return res.status(400).json({
        success: false,
        message: 'Confirmation is required to delete a user account',
      });
    }

    const removed = await userAdminService.deleteUser(userId, req.user.id);

    await auditLogService.recordForRequest(req, 'ADMIN_DELETED_USER', {
      targetType: 'User',
      targetId: userId,
      metadata: {
        removedEmail: removed.email,
        removedRole: removed.role,
        // Explicitly documents that no emergency/allocation history existed.
        historyPreserved: true,
      },
    });
    res.json({ success: true, deletedUserId: removed.id });
  } catch (error) {
    if (error instanceof userAdminService.UserAdminError) {
      return res.status(error.statusCode).json({
        success: false,
        code: error.code,
        message: error.message,
      });
    }
    // Prisma's own foreign-key guard is the last line of defence: a user that
    // still has history is reported as a conflict, never as a 500.
    if (error && (error.code === 'P2003' || error.code === 'P2014')) {
      return res.status(409).json({
        success: false,
        code: 'USER_HAS_HISTORY',
        message:
          'This account is still referenced by emergency or allocation history and cannot be deleted. Deactivate it instead.',
      });
    }
    next(error);
  }
};

exports.updateUserRole = async (req, res, next) => {
  try {
    const userId = positiveInteger(req.params.id);
    if (!userId) {
      return res.status(400).json({ success: false, message: 'Invalid user id' });
    }

    const allowedRoles = ['REQUESTER', 'RESPONDER', 'ADMIN'];
    if (!allowedRoles.includes(req.body && req.body.role)) {
      return res.status(400).json({ success: false, message: 'Invalid role' });
    }
    if (userId === req.user.userId && req.body.role !== 'ADMIN') {
      return res.status(400).json({ success: false, message: 'You cannot demote your own admin account' });
    }
    // ERAS must never lose its last administrator: demoting the only remaining
    // ADMIN would lock every operator out of user management.
    const target = await prisma.user.findUnique({
      where: { id: userId },
      select: { id: true, role: true, isActive: true },
    });
    if (!target) {
      return res.status(404).json({ success: false, message: 'User not found' });
    }
    if (target.role === 'ADMIN' && req.body.role !== 'ADMIN') {
      const activeAdmins = await prisma.user.count({
        where: { role: 'ADMIN', isActive: true },
      });
      if (activeAdmins <= 1) {
        return res.status(400).json({
          success: false,
          message: 'At least one active administrator account must remain',
        });
      }
    }
    // Only the role column is written - never a spread of the request body.
    const user = await prisma.user.update({
      where: { id: userId },
      data: { role: req.body.role },
      select: { id: true, name: true, email: true, role: true, isActive: true },
    });
    await auditLogService.recordForRequest(req, 'ADMIN_CHANGED_USER_ROLE', {
      targetType: 'User',
      targetId: userId,
      metadata: { role: req.body.role },
    });
    res.json({ success: true, user });
  } catch (error) {
    next(error);
  }
};

exports.activateUser = async (req, res, next) => {
  try {
    const userId = positiveInteger(req.params.id);
    if (!userId) {
      return res.status(400).json({ success: false, message: 'Invalid user id' });
    }
    const user = await prisma.user.update({
      where: { id: userId },
      data: { isActive: true },
      select: { id: true, name: true, email: true, role: true, isActive: true },
    });
    await auditLogService.recordForRequest(req, 'ADMIN_ACTIVATED_USER', {
      targetType: 'User',
      targetId: userId,
    });
    res.json({ success: true, user });
  } catch (error) {
    next(error);
  }
};

exports.deactivateUser = async (req, res, next) => {
  try {
    const userId = positiveInteger(req.params.id);
    if (!userId) {
      return res.status(400).json({ success: false, message: 'Invalid user id' });
    }
    if (userId === req.user.userId) {
      return res.status(400).json({ success: false, message: 'You cannot deactivate your own account' });
    }
    // Deactivating the last administrator would remove every admin session.
    const target = await prisma.user.findUnique({
      where: { id: userId },
      select: { id: true, role: true },
    });
    if (!target) {
      return res.status(404).json({ success: false, message: 'User not found' });
    }
    if (target.role === 'ADMIN') {
      const activeAdmins = await prisma.user.count({
        where: { role: 'ADMIN', isActive: true },
      });
      if (activeAdmins <= 1) {
        return res.status(400).json({
          success: false,
          message: 'At least one active administrator account must remain',
        });
      }
    }
    const user = await prisma.user.update({
      where: { id: userId },
      data: { isActive: false, responderStatus: 'OFFLINE' },
      select: { id: true, name: true, email: true, role: true, isActive: true },
    });
    await auditLogService.recordForRequest(req, 'ADMIN_DEACTIVATED_USER', {
      targetType: 'User',
      targetId: userId,
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
    //
    // Archived after-action logs stay in PostgreSQL for history but are hidden
    // from normal listings; ADMIN may explicitly request them.
    const includeArchived = String(req.query.includeArchived || '') === 'true';
    const requests = await requestService.getAllRequests('ADMIN', { includeArchived });
    res.json({ success: true, requests });
  } catch (error) {
    next(error);
  }
};

exports.getAllAllocations = async (req, res, next) => {
  try {
    const allocations = await prisma.allocation.findMany({
      orderBy: { id: 'asc' },
    });
    res.json({ success: true, allocations });
  } catch (error) {
    next(error);
  }
};

/**
 * ADMIN-only removal of one after-action/application log entry.
 *
 * The visible log entry is ARCHIVED (archivedAt/archivedById), not destroyed:
 * operational/audit history stays in PostgreSQL and can still be inspected by
 * an administrator explicitly asking for archived rows. The security audit
 * trail is never touched - instead this action appends an ADMIN_DELETED_LOG
 * event, so the deletion itself remains auditable.
 *
 * Guard rails: ADMIN role (route level), valid id, terminal request only
 * (never an active emergency), explicit confirmation flag from the client, and
 * a dedicated rate limiter so bulk deletion cannot be scripted casually.
 */
exports.deleteLogEntry = async (req, res, next) => {
  try {
    const requestId = positiveInteger(req.params.id);
    if (!requestId) {
      return res.status(400).json({ success: false, message: 'Invalid log id' });
    }
    if (req.body && req.body.confirm !== true) {
      return res.status(400).json({
        success: false,
        message: 'Confirmation is required to delete a log entry',
      });
    }

    const archived = await requestService.archiveRequestForAdmin(requestId, req.user.id);

    await auditLogService.recordForRequest(req, 'ADMIN_DELETED_LOG', {
      targetType: 'EmergencyRequest',
      targetId: requestId,
      metadata: {
        status: archived.status,
        archivedAt: archived.archivedAt,
        // Explicitly documents that no security record was destroyed.
        preservedSecurityAudit: true,
      },
    });

    res.json({ success: true, logId: requestId, archivedAt: archived.archivedAt });
  } catch (error) {
    // The service states the rule AND the status code, so a business rejection
    // can never be reported as an unexpected 500. The message checks remain as
    // a defensive fallback for older call paths.
    if (error.statusCode === 404 || /not found/i.test(error.message || '')) {
      return res.status(404).json({ success: false, message: error.message });
    }
    if (
      error.statusCode === 400 ||
      /active|already|closed|completed or cancelled/i.test(error.message || '')
    ) {
      return res.status(400).json({ success: false, message: error.message });
    }
    next(error);
  }
};

/**
 * ADMIN-only, read-only view of the append-only security audit trail. There is
 * deliberately NO endpoint that deletes audit rows.
 */
exports.getAuditLogs = async (req, res, next) => {
  try {
    const limit = Math.min(200, Math.max(1, Number(req.query.limit) || 100));
    const logs = await prisma.auditLog.findMany({
      orderBy: { id: 'desc' },
      take: limit,
      select: {
        id: true,
        event: true,
        actorId: true,
        actorRole: true,
        targetType: true,
        targetId: true,
        metadata: true,
        createdAt: true,
      },
    });
    res.json({ success: true, logs });
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
    //
    // This endpoint is ADMIN-only, so responder contact details are included.
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
          ? await requestService.getCompatibleRequestsForResponder(row.id, 'ADMIN')
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
