const prisma = require('../config/prisma');
const {
  validateEmergencyRequestInput,
  normalizeRequiredResources,
} = require('../validators/requestValidator');
const { runSerializableTransaction } = require('./transactionService');
const { ACTIVE_REQUEST_STATUSES, syncResponderAvailability } = require('./lifecycleService');
const {
  emitAllocationsForRequest,
  emitRequestCreated,
  emitRequestUpdated,
  emitResponderAvailability,
} = require('../realtime/eventEmitters');
const { getIO } = require('../realtime/socketEvents');

async function emitAfterCommit(callback) {
  try {
    await callback();
  } catch (error) {
    // A socket/database read failure after a successful REST commit must not
    // turn a committed mutation into a misleading HTTP failure.
    console.error('Realtime emission failed:', error.message);
  }
}

const requesterSelect = {
  id: true,
  name: true,
  email: true,
  phone: true,
};

const responderSelect = {
  id: true,
  name: true,
  email: true,
  phone: true,
  responderStatus: true,
  location: true,
  latitude: true,
  longitude: true,
  lastActiveAt: true,
};

// Every board response is database-backed and carries the resource IDs needed
// by the frontend. Resource labels are display-only; matching never uses them.
const requestInclude = {
  requiredResources: { include: { resource: true } },
  requester: { select: requesterSelect },
  acceptedBy: { select: responderSelect },
  allocations: {
    include: {
      resource: {
        select: { id: true, name: true, type: true, unit: true },
      },
      responder: { select: { id: true, name: true, phone: true } },
    },
  },
};

exports.requestInclude = requestInclude;

exports.createEmergencyRequest = async (userId, data) => {
  const validationError = validateEmergencyRequestInput(data);
  if (validationError) throw new Error(validationError);

  const requiredResources = normalizeRequiredResources(data.requiredResources);
  const resourceIds = requiredResources.map((resource) => resource.resourceId);
  const resources = await prisma.resource.findMany({
    where: { id: { in: resourceIds } },
  });
  const resourceById = new Map(resources.map((resource) => [resource.id, resource]));

  for (const required of requiredResources) {
    const resource = resourceById.get(required.resourceId);
    if (!resource) throw new Error(`Resource ${required.resourceId} does not exist`);
    if (!resource.isActive) {
      throw new Error(`Resource "${resource.name}" is not active`);
    }

    // SERVICE resources are reusable responder capabilities, not inventory.
    // Their availability is a function of responder capacity at
    // matching/acceptance time, never a static catalog quantity.
    if (resource.mode === 'CONSUMABLE') {
      if (resource.availableQuantity <= 0) {
        throw new Error(`Resource "${resource.name}" is out of stock`);
      }
      if (required.quantity > resource.availableQuantity) {
        throw new Error(
          `Only ${resource.availableQuantity} of "${resource.name}" are currently available`
        );
      }
    }
  }

  const created = await prisma.emergencyRequest.create({
    data: {
      emergencyType: String(data.emergencyType).trim(),
      description: String(data.description).trim(),
      location: String(data.location).trim(),
      latitude: typeof data.latitude === 'number' ? data.latitude : null,
      longitude: typeof data.longitude === 'number' ? data.longitude : null,
      priority: data.priority ? String(data.priority) : 'MEDIUM',
      requesterId: userId,
      requiredResources: {
        create: requiredResources.map((resource) => ({
          resourceId: resource.resourceId,
          quantity: resource.quantity,
        })),
      },
    },
    include: requestInclude,
  });

  // Matching is evaluated only after PostgreSQL has committed the request.
  // The same compatibility implementation used by GET /compatible is reused
  // here; the event never grants acceptance or persistence authority.
  await emitAfterCommit(async () => {
    if (!getIO()) return;
    const responders = await prisma.user.findMany({
      where: { role: 'RESPONDER', isActive: true },
      select: { id: true },
    });
    const compatibleResponderIds = [];
    for (const responder of responders) {
      const compatible = await exports.getCompatibleRequestsForResponder(responder.id);
      if (compatible.some((candidate) => candidate.id === created.id)) {
        compatibleResponderIds.push(responder.id);
      }
    }
    await emitRequestCreated(created, compatibleResponderIds);
  });

  return created;
};

exports.getRequestsByUser = async (userId) =>
  prisma.emergencyRequest.findMany({
    where: { requesterId: Number(userId) },
    include: requestInclude,
    orderBy: { createdAt: 'desc' },
  });

exports.getRequestById = async (id) => {
  const request = await prisma.emergencyRequest.findUnique({
    where: { id: Number(id) },
    include: requestInclude,
  });
  if (!request) throw new Error('Request not found');
  return request;
};

/**
 * Cancel is a cleanup transaction, not only a request flag update. Every
 * reservation or dispatch is converted to CANCELLED exactly once and its
 * inventory is restored exactly once. Delivered allocations are deliberately
 * left untouched because those units have already left the responder.
 */
exports.cancelEmergencyRequest = async (userId, id) => {
  const requestId = Number(id);
  if (!Number.isInteger(requestId) || requestId <= 0) {
    throw new Error('Request not found');
  }

  const cancelled = await runSerializableTransaction(async (tx) => {
    const lockedRequests = await tx.$queryRaw`
      SELECT id, "requesterId", "acceptedById", status
      FROM "EmergencyRequest"
      WHERE id = ${requestId}
      FOR UPDATE
    `;
    const request = lockedRequests[0];
    if (!request) throw new Error('Request not found');
    if (request.requesterId !== Number(userId)) {
      throw new Error('Unauthorized: You can only cancel your own requests');
    }
    if (request.status === 'CANCELLED') {
      throw new Error('Request has already been cancelled');
    }
    if (request.status === 'COMPLETED') {
      throw new Error('Completed requests cannot be cancelled');
    }

    const candidates = await tx.allocation.findMany({
      where: {
        requestId,
        status: { in: ['RESERVED', 'DISPATCHED'] },
      },
      select: { id: true },
    });
    const affectedResponders = new Set();
    if (request.acceptedById) affectedResponders.add(request.acceptedById);

    for (const candidate of candidates) {
      const lockedAllocations = await tx.$queryRaw`
        SELECT id, "responderId", "responderResourceId", "resourceId", quantity, status
        FROM "Allocation"
        WHERE id = ${candidate.id}
        FOR UPDATE
      `;
      const allocation = lockedAllocations[0];
      if (
        !allocation ||
        (allocation.status !== 'RESERVED' && allocation.status !== 'DISPATCHED')
      ) {
        continue;
      }

      const allocationResource = await tx.resource.findUnique({
        where: { id: allocation.resourceId },
        select: { mode: true },
      });

      // Restore inventory only for CONSUMABLE allocations that were not
      // DELIVERED. SERVICE allocations never decremented inventory, so
      // cancelling them must never fabricate stock.
      if (!allocationResource || allocationResource.mode === 'CONSUMABLE') {
        const lockedResources = await tx.$queryRaw`
          SELECT id, "availableQuantity", "totalQuantity", "isEnabled", status
          FROM "ResponderResource"
          WHERE id = ${allocation.responderResourceId}
          FOR UPDATE
        `;
        const responderResource = lockedResources[0];
        if (!responderResource) throw new Error('Responder resource not found');

        const restoredQuantity =
          responderResource.availableQuantity + allocation.quantity;
        if (restoredQuantity > responderResource.totalQuantity) {
          throw new Error('Inventory restoration would exceed total quantity');
        }

        await tx.responderResource.update({
          where: { id: allocation.responderResourceId },
          data: {
            availableQuantity: restoredQuantity,
            ...(responderResource.isEnabled && restoredQuantity > 0
              ? { status: 'AVAILABLE' }
              : {}),
          },
        });
      }
      await tx.allocation.update({
        where: { id: allocation.id },
        data: { status: 'CANCELLED' },
      });
      affectedResponders.add(allocation.responderId);
    }

    const cancelled = await tx.emergencyRequest.update({
      where: { id: requestId },
      data: { status: 'CANCELLED' },
      include: requestInclude,
    });

    for (const responderId of affectedResponders) {
      await syncResponderAvailability(tx, responderId);
    }

    return cancelled;
  });

  await emitAfterCommit(async () => {
    await emitRequestUpdated(requestId);
    await emitAllocationsForRequest(requestId);
    const accepted = cancelled.acceptedById;
    if (accepted) await emitResponderAvailability(accepted);
  });

  return cancelled;
};

exports.getAllRequests = async () =>
  prisma.emergencyRequest.findMany({
    include: requestInclude,
    orderBy: { createdAt: 'desc' },
  });

exports.getAssignedRequestsForResponder = async (responderId) =>
  prisma.emergencyRequest.findMany({
    where: { acceptedById: Number(responderId) },
    include: requestInclude,
    orderBy: { createdAt: 'desc' },
  });

exports.getCompatibleRequestsForResponder = async (responderId) => {
  const numericResponderId = Number(responderId);
  const responder = await prisma.user.findUnique({
    where: { id: numericResponderId },
    select: { id: true, role: true, isActive: true, responderStatus: true },
  });

  if (
    !responder ||
    responder.role !== 'RESPONDER' ||
    !responder.isActive ||
    responder.responderStatus !== 'AVAILABLE'
  ) {
    return [];
  }

  const activeEmergency = await prisma.emergencyRequest.findFirst({
    where: {
      acceptedById: numericResponderId,
      status: { in: ACTIVE_REQUEST_STATUSES },
    },
    select: { id: true },
  });
  if (activeEmergency) return [];

  // A capability must explicitly be enabled. Joining the resource catalog
  // ensures a disabled/inactive catalog resource can never match. Quantity
  // and status are only meaningful for CONSUMABLE resources, so they are
  // evaluated per-mode below rather than filtered out of this query.
  const responderResources = await prisma.responderResource.findMany({
    where: {
      responderId: numericResponderId,
      isEnabled: true,
      resource: { isActive: true },
    },
    select: {
      resourceId: true,
      availableQuantity: true,
      status: true,
      isEnabled: true,
      resource: { select: { mode: true, isActive: true } },
    },
  });

  const requests = await prisma.emergencyRequest.findMany({
    where: { status: 'PENDING' },
    include: requestInclude,
    orderBy: [{ priority: 'desc' }, { createdAt: 'asc' }],
  });

  return requests.filter((request) => {
    if (!request.requiredResources.length) return false;

    return request.requiredResources.every((required) => {
      if (!required.resource.isActive) return false;

      // Strict integer resourceId matching; names/types are never used.
      const candidate = responderResources.find(
        (resource) => resource.resourceId === required.resourceId
      );
      if (!candidate || !candidate.resource.isActive) return false;

      if (candidate.resource.mode === 'SERVICE') {
        // Reusable capability: isEnabled + active resource is sufficient.
        // Quantity/status never gate a SERVICE match.
        return true;
      }

      // CONSUMABLE: the responder must have real, available inventory.
      return (
        candidate.status === 'AVAILABLE' &&
        candidate.availableQuantity >= required.quantity
      );
    });
  });
};

exports.acceptEmergencyRequest = async (responderId, requestId) => {
  const numericResponderId = Number(responderId);
  const numericRequestId = Number(requestId);
  if (!Number.isInteger(numericRequestId) || numericRequestId <= 0) {
    throw new Error('Request not found');
  }

  const acceptedRequest = await runSerializableTransaction(async (tx) => {
    // Retain explicit row locks for acceptance. The user lock serializes two
    // different requests racing to be accepted by one responder.
    const lockedRequests = await tx.$queryRaw`
      SELECT id, status
      FROM "EmergencyRequest"
      WHERE id = ${numericRequestId}
      FOR UPDATE
    `;
    const requestRow = lockedRequests[0];
    if (!requestRow) throw new Error('Request not found');
    if (requestRow.status !== 'PENDING') {
      throw new Error('Only PENDING requests can be accepted');
    }

    const lockedResponders = await tx.$queryRaw`
      SELECT id, role, "isActive", "responderStatus"
      FROM "User"
      WHERE id = ${numericResponderId}
      FOR UPDATE
    `;
    const responder = lockedResponders[0];
    if (!responder || responder.role !== 'RESPONDER') {
      throw new Error('Only responders can accept emergencies');
    }
    if (!responder.isActive) throw new Error('Responder is inactive');
    if (responder.responderStatus !== 'AVAILABLE') {
      throw new Error('Responder is not available to accept');
    }

    const activeEmergency = await tx.emergencyRequest.findFirst({
      where: {
        acceptedById: numericResponderId,
        status: { in: ACTIVE_REQUEST_STATUSES },
      },
      select: { id: true },
    });
    if (activeEmergency) {
      throw new Error('Responder already has an active emergency');
    }

    const requiredResources = await tx.requestResource.findMany({
      where: { requestId: numericRequestId },
      select: { resourceId: true, quantity: true },
    });
    if (!requiredResources.length) {
      throw new Error('Request has no required resource');
    }

    // Lock all capability rows before the compatibility re-check so changes
    // made after GET /compatible cannot race this acceptance.
    const responderResources = await tx.$queryRaw`
      SELECT rr.id, rr."resourceId", rr."availableQuantity", rr.status,
             rr."isEnabled", resource."isActive" AS "resourceIsActive",
             resource."mode" AS "resourceMode"
      FROM "ResponderResource" AS rr
      INNER JOIN "Resource" AS resource ON resource.id = rr."resourceId"
      WHERE rr."responderId" = ${numericResponderId}
      FOR UPDATE OF rr, resource
    `;

    for (const required of requiredResources) {
      const matching = responderResources.find((resource) => {
        if (resource.resourceId !== required.resourceId) return false;
        if (!resource.isEnabled || !resource.resourceIsActive) return false;

        if (resource.resourceMode === 'SERVICE') {
          // Reusable capability: no quantity ceiling and no dependence on
          // the ResponderResource.status column (that column only tracks
          // consumable stock availability).
          return true;
        }

        return (
          resource.status === 'AVAILABLE' &&
          resource.availableQuantity >= required.quantity
        );
      });
      if (!matching) {
        throw new Error('Responder does not have the required resource available');
      }
    }

    const updatedRequest = await tx.emergencyRequest.update({
      where: { id: numericRequestId },
      data: {
        status: 'ACCEPTED',
        acceptedById: numericResponderId,
        acceptedAt: new Date(),
      },
      include: requestInclude,
    });

    await tx.user.update({
      where: { id: numericResponderId },
      data: { lastActiveAt: new Date() },
    });
    await syncResponderAvailability(tx, numericResponderId);

    return updatedRequest;
  });

  await emitAfterCommit(async () => {
    await emitRequestUpdated(numericRequestId, [numericResponderId]);
    await emitResponderAvailability(numericResponderId);
  });

  return acceptedRequest;
};

exports.updateRequestStatus = async (requestId, status) => {
  const updated = await prisma.emergencyRequest.update({
    where: { id: Number(requestId) },
    data: { status },
  });
  await emitAfterCommit(() => emitRequestUpdated(Number(requestId)));
  return updated;
};
