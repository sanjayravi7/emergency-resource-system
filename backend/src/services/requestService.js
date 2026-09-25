const prisma = require('../config/prisma');
const {
  validateEmergencyRequestInput,
  normalizeRequiredResources,
} = require('../validators/requestValidator');
const { runSerializableTransaction } = require('./transactionService');
const { ACTIVE_REQUEST_STATUSES, syncResponderAvailability } = require('./lifecycleService');

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
    if (resource.availableQuantity <= 0) {
      throw new Error(`Resource "${resource.name}" is out of stock`);
    }
    if (required.quantity > resource.availableQuantity) {
      throw new Error(
        `Only ${resource.availableQuantity} of "${resource.name}" are currently available`
      );
    }
  }

  return prisma.emergencyRequest.create({
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

  return runSerializableTransaction(async (tx) => {
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
        SELECT id, "responderId", "responderResourceId", quantity, status
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

  // A capability must explicitly be enabled and presently available. Joining
  // the resource catalog ensures a disabled catalog resource cannot match.
  const responderResources = await prisma.responderResource.findMany({
    where: {
      responderId: numericResponderId,
      isEnabled: true,
      status: 'AVAILABLE',
      availableQuantity: { gt: 0 },
      resource: { isActive: true },
    },
    select: {
      resourceId: true,
      availableQuantity: true,
      status: true,
      isEnabled: true,
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
      // Strict integer resourceId matching; names/types are never used.
      const matchingResource = responderResources.find(
        (resource) =>
          resource.resourceId === required.resourceId &&
          resource.availableQuantity >= required.quantity
      );
      return Boolean(matchingResource && required.resource.isActive);
    });
  });
};

exports.acceptEmergencyRequest = async (responderId, requestId) => {
  const numericResponderId = Number(responderId);
  const numericRequestId = Number(requestId);
  if (!Number.isInteger(numericRequestId) || numericRequestId <= 0) {
    throw new Error('Request not found');
  }

  return runSerializableTransaction(async (tx) => {
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
             rr."isEnabled", resource."isActive" AS "resourceIsActive"
      FROM "ResponderResource" AS rr
      INNER JOIN "Resource" AS resource ON resource.id = rr."resourceId"
      WHERE rr."responderId" = ${numericResponderId}
      FOR UPDATE OF rr, resource
    `;

    for (const required of requiredResources) {
      const matching = responderResources.find(
        (resource) =>
          resource.resourceId === required.resourceId &&
          resource.isEnabled === true &&
          resource.status === 'AVAILABLE' &&
          resource.resourceIsActive === true &&
          resource.availableQuantity >= required.quantity
      );
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
};

exports.updateRequestStatus = async (requestId, status) =>
  prisma.emergencyRequest.update({
    where: { id: Number(requestId) },
    data: { status },
  });
