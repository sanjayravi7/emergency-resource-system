const prisma = require('../config/prisma');
const { emitToRooms, getIO, rooms } = require('./socketEvents');

const requesterSelect = {
  id: true,
  name: true,
  email: true,
  phone: true,
};

const acceptedBySelect = {
  id: true,
  name: true,
  phone: true,
  responderStatus: true,
  location: true,
  latitude: true,
  longitude: true,
  lastActiveAt: true,
};

const requestInclude = {
  requiredResources: {
    include: {
      resource: {
        select: { id: true, name: true, type: true, mode: true, unit: true },
      },
    },
  },
  requester: { select: requesterSelect },
  acceptedBy: { select: acceptedBySelect },
  allocations: {
    include: {
      resource: {
        select: { id: true, name: true, type: true, mode: true, unit: true },
      },
      responder: { select: { id: true, name: true, phone: true } },
    },
  },
};

function requestPayload(request) {
  if (!request) return null;
  return {
    id: request.id,
    requesterId: request.requesterId,
    emergencyType: request.emergencyType,
    description: request.description,
    location: request.location,
    latitude: request.latitude,
    longitude: request.longitude,
    priority: request.priority,
    status: request.status,
    acceptedById: request.acceptedById,
    acceptedAt: request.acceptedAt,
    createdAt: request.createdAt,
    updatedAt: request.updatedAt,
    requester: request.requester
      ? {
          id: request.requester.id,
          name: request.requester.name,
          email: request.requester.email,
          phone: request.requester.phone,
        }
      : null,
    acceptedBy: request.acceptedBy
      ? {
          id: request.acceptedBy.id,
          name: request.acceptedBy.name,
          responderStatus: request.acceptedBy.responderStatus,
          location: request.acceptedBy.location,
          latitude: request.acceptedBy.latitude,
          longitude: request.acceptedBy.longitude,
          lastActiveAt: request.acceptedBy.lastActiveAt,
        }
      : null,
    requiredResources: (request.requiredResources || []).map((required) => ({
      id: required.id,
      requestId: required.requestId,
      resourceId: required.resourceId,
      quantity: required.quantity,
      resource: required.resource
        ? {
            id: required.resource.id,
            name: required.resource.name,
            type: required.resource.type,
            mode: required.resource.mode,
            unit: required.resource.unit,
          }
        : undefined,
    })),
    allocations: (request.allocations || []).map((allocation) => ({
      id: allocation.id,
      requestId: allocation.requestId,
      resourceId: allocation.resourceId,
      responderId: allocation.responderId,
      responderResourceId: allocation.responderResourceId,
      quantity: allocation.quantity,
      status: allocation.status,
      allocatedAt: allocation.allocatedAt,
      updatedAt: allocation.updatedAt,
      resource: allocation.resource,
      responder: allocation.responder
        ? { id: allocation.responder.id, name: allocation.responder.name }
        : null,
    })),
  };
}

function allocationPayload(allocation) {
  if (!allocation) return null;
  return {
    id: allocation.id,
    allocationId: allocation.id,
    requestId: allocation.requestId,
    resourceId: allocation.resourceId,
    responderId: allocation.responderId,
    responderResourceId: allocation.responderResourceId,
    quantity: allocation.quantity,
    status: allocation.status,
    allocatedAt: allocation.allocatedAt,
    updatedAt: allocation.updatedAt,
    resource: allocation.resource,
    responder: allocation.responder
      ? { id: allocation.responder.id, name: allocation.responder.name }
      : null,
  };
}

async function loadRequest(requestId) {
  return prisma.emergencyRequest.findUnique({
    where: { id: Number(requestId) },
    include: requestInclude,
  });
}

async function loadAllocation(allocationId) {
  return prisma.allocation.findUnique({
    where: { id: Number(allocationId) },
    include: {
      resource: {
        select: { id: true, name: true, type: true, mode: true, unit: true },
      },
      responder: { select: { id: true, name: true, phone: true } },
    },
  });
}

function requestRooms(request, extraUserIds = []) {
  const userIds = new Set(extraUserIds.map(Number));
  if (request?.requesterId) userIds.add(request.requesterId);
  if (request?.acceptedById) userIds.add(request.acceptedById);

  // Full request/allocation snapshots are restricted to the request room,
  // owning requester, assigned responder(s), and admins. Never use the global
  // responder room for operational/requester data.
  return [
    rooms.request(request.id),
    ...[...userIds].map((userId) => rooms.user(userId)),
    rooms.admins,
  ];
}

/** Emit after the caller's REST transaction has resolved/committed. */
async function emitRequestCreated(request, compatibleResponderIds = []) {
  if (!getIO() || !request) return;
  const payload = {
    requestId: request.id,
    status: request.status,
    emergencyType: request.emergencyType,
    location: request.location,
    latitude: request.latitude,
    longitude: request.longitude,
    priority: request.priority,
    requiredResources: (request.requiredResources || []).map((required) => ({
      resourceId: required.resourceId,
      quantity: required.quantity,
      resource: required.resource
        ? {
            id: required.resource.id,
            name: required.resource.name,
            type: required.resource.type,
            mode: required.resource.mode,
            unit: required.resource.unit,
          }
        : undefined,
    })),
    requester: request.requester
      ? {
          id: request.requester.id,
          name: request.requester.name,
          email: request.requester.email,
          phone: request.requester.phone,
        }
      : { id: request.requesterId },
    createdAt: request.createdAt,
    request: requestPayload(request),
  };

  const targetRooms = [rooms.user(request.requesterId), rooms.admins];
  for (const responderId of compatibleResponderIds) {
    targetRooms.push(rooms.user(responderId));
  }
  emitToRooms('request.created', payload, targetRooms);
}

async function emitRequestUpdated(requestId, extraUserIds = []) {
  if (!getIO()) return;
  const request = await loadRequest(requestId);
  if (!request) return;

  const payload = {
    requestId: request.id,
    status: request.status,
    acceptedBy: request.acceptedBy
      ? {
          id: request.acceptedBy.id,
          name: request.acceptedBy.name,
          responderStatus: request.acceptedBy.responderStatus,
          location: request.acceptedBy.location,
          latitude: request.acceptedBy.latitude,
          longitude: request.acceptedBy.longitude,
          lastActiveAt: request.acceptedBy.lastActiveAt,
        }
      : null,
    acceptedById: request.acceptedById,
    acceptedAt: request.acceptedAt,
    updatedAt: request.updatedAt,
    request: requestPayload(request),
  };
  const targetRooms = requestRooms(request, extraUserIds);
  emitToRooms('request.updated', payload, targetRooms);

  // Responders who previously received a compatible PENDING request need to
  // remove it after acceptance/cancellation, but are not entitled to the full
  // requester snapshot. A redacted invalidation carries only availability.
  emitToRooms('request.updated', {
    requestId: request.id,
    status: request.status,
    available: request.status === 'PENDING',
    updatedAt: request.updatedAt,
  }, [rooms.responders]);

  if (
    ['COMPLETED', 'CANCELLED'].includes(request.status) &&
    request.acceptedById
  ) {
    emitToRooms('responder.location.stop', {
      requestId: request.id,
      responderId: request.acceptedById,
      timestamp: new Date().toISOString(),
    }, [
      rooms.request(request.id),
      rooms.user(request.requesterId),
      rooms.user(request.acceptedById),
      rooms.admins,
    ]);
  }
}

async function emitAllocationUpdated(allocationId) {
  if (!getIO()) return;
  const allocation = await loadAllocation(allocationId);
  if (!allocation) return;

  const request = await loadRequest(allocation.requestId);
  const payload = {
    allocationId: allocation.id,
    requestId: allocation.requestId,
    status: allocation.status,
    quantity: allocation.quantity,
    resourceId: allocation.resourceId,
    responderId: allocation.responderId,
    updatedAt: allocation.updatedAt,
    allocation: allocationPayload(allocation),
    requestStatus: request?.status,
  };

  const targetRooms = requestRooms(request || { id: allocation.requestId }, [
    allocation.responderId,
  ]);
  emitToRooms('allocation.updated', payload, targetRooms);

  // The request status is derived in PostgreSQL. Sending the fresh request
  // snapshot prevents Flutter from inventing a competing lifecycle machine.
  if (request) await emitRequestUpdated(request.id, [allocation.responderId]);
}

async function emitAllocationsForRequest(requestId) {
  const allocations = await prisma.allocation.findMany({
    where: { requestId: Number(requestId), status: 'CANCELLED' },
    select: { id: true },
  });
  for (const allocation of allocations) {
    await emitAllocationUpdated(allocation.id);
  }
}

async function emitResponderAvailability(responderId) {
  if (!getIO()) return;
  const responder = await prisma.user.findUnique({
    where: { id: Number(responderId) },
    select: { id: true, responderStatus: true },
  });
  if (!responder) return;

  emitToRooms('responder.availability', {
    responderId: responder.id,
    currentResponderStatus: responder.responderStatus,
    responderStatus: responder.responderStatus,
    timestamp: new Date().toISOString(),
  }, [rooms.user(responder.id), rooms.responders, rooms.admins]);
}

module.exports = {
  allocationPayload,
  emitAllocationsForRequest,
  emitAllocationUpdated,
  emitRequestCreated,
  emitRequestUpdated,
  emitResponderAvailability,
  requestPayload,
};
