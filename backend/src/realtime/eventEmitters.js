const prisma = require('../config/prisma');
const { emitToRooms, getIO, rooms } = require('./socketEvents');
const {
  ACTIVE_REQUEST_STATUSES,
  UNFINISHED_ALLOCATION_STATUSES,
  computeOutstandingByResource,
} = require('../services/lifecycleService');

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

// Assignment responders are exposed exactly like the acceptedBy responder:
// operational identity only (no email, no credentials).
const assignmentResponderSelect = acceptedBySelect;

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
  assignments: {
    include: {
      responder: { select: assignmentResponderSelect },
    },
  },
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
    assignments: (request.assignments || []).map((assignment) => ({
      id: assignment.id,
      requestId: assignment.requestId,
      responderId: assignment.responderId,
      status: assignment.status,
      acceptedAt: assignment.acceptedAt,
      endedAt: assignment.endedAt,
      createdAt: assignment.createdAt,
      updatedAt: assignment.updatedAt,
      responder: assignment.responder
        ? {
            id: assignment.responder.id,
            name: assignment.responder.name,
            phone: assignment.responder.phone,
            responderStatus: assignment.responder.responderStatus,
            location: assignment.responder.location,
            latitude: assignment.responder.latitude,
            longitude: assignment.responder.longitude,
            lastActiveAt: assignment.responder.lastActiveAt,
          }
        : null,
    })),
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

  // Multi-responder dispatch: every responder with an ACTIVE assignment on
  // the request receives the full update through their own user room (they
  // may not have joined the request room). ResponderAssignment is the
  // authoritative membership; acceptedById above covers legacy lead rows.
  for (const assignment of request?.assignments || []) {
    if (assignment.status === 'ACTIVE') userIds.add(assignment.responderId);
  }

  // Full request/allocation snapshots are restricted to the request room,
  // owning requester, assigned responder(s), and admins. Never use the global
  // responder room for operational/requester data.
  return [
    rooms.request(request.id),
    ...[...userIds].map((userId) => rooms.user(userId)),
    rooms.admins,
  ];
}

/**
 * The redacted responders-room "still joinable" signal. Under multi-responder
 * dispatch an ACCEPTED / IN_PROGRESS / PARTIALLY_ALLOCATED request can still
 * have outstanding required quantity, so terminal status and outstanding
 * quantity - not `status === 'PENDING'` - decide joinability. This is only a
 * coarse broadcast hint; GET /api/requests/compatible remains authoritative
 * for a specific responder.
 */
function requestStillJoinable(request) {
  if (!request) return false;
  if (!['PENDING', ...ACTIVE_REQUEST_STATUSES].includes(request.status)) {
    return false;
  }
  if (request.status === 'PENDING') {
    // PENDING is always potentially joinable while required lines exist.
    return (request.requiredResources || []).length > 0;
  }
  const outstandingByResource = computeOutstandingByResource(
    request.requiredResources || [],
    request.allocations || []
  );
  for (const outstanding of outstandingByResource.values()) {
    if (outstanding > 0) return true;
  }
  return false;
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

  // Responders who previously received a compatible request need to know
  // whether it is still joinable, but are not entitled to the full requester
  // snapshot. A redacted invalidation carries only the coarse joinability
  // signal; the compatibility endpoint stays authoritative per responder.
  emitToRooms('request.updated', {
    requestId: request.id,
    status: request.status,
    available: requestStillJoinable(request),
    updatedAt: request.updatedAt,
  }, [rooms.responders]);

  if (['COMPLETED', 'CANCELLED'].includes(request.status)) {
    // Terminal cleanup is per responder: every participant who may be
    // streaming a location for this request gets their own stop event, so
    // one responder's stream ends without terminating anyone else's. The
    // lead covers legacy rows; ACTIVE assignments cover everyone else.
    const terminalResponderIds = new Set();
    if (request.acceptedById) terminalResponderIds.add(request.acceptedById);
    for (const assignment of request.assignments || []) {
      if (assignment.status === 'ACTIVE') {
        terminalResponderIds.add(assignment.responderId);
      }
    }
    // Allocation-only participants may also be streaming a location
    // (createAllocation intentionally needs no assignment), so their streams
    // must stop as well. Extra stop signals are harmless idempotent hints.
    for (const allocation of request.allocations || []) {
      terminalResponderIds.add(allocation.responderId);
    }

    const timestamp = new Date().toISOString();
    for (const responderId of terminalResponderIds) {
      emitToRooms('responder.location.stop', {
        requestId: request.id,
        responderId,
        timestamp,
      }, [
        rooms.request(request.id),
        rooms.user(request.requesterId),
        rooms.user(responderId),
        rooms.admins,
      ]);
    }
  }
}

/**
 * Emit after the caller's REST transaction has resolved/committed (the
 * acceptance transaction creates the ResponderAssignment).
 *
 * `responder.assigned` is the per-responder assignment confirmation for
 * multi-responder dispatch: the assigned responder gets their own assignment,
 * while the request room, the requester, and admins receive the updated
 * multi-responder state (full assignments[] list plus the request snapshot).
 */
async function emitResponderAssigned(requestId, responderId) {
  if (!getIO()) return;
  const numericRequestId = Number(requestId);
  const numericResponderId = Number(responderId);

  const [assignment, request] = await Promise.all([
    prisma.responderAssignment.findFirst({
      where: {
        requestId: numericRequestId,
        responderId: numericResponderId,
      },
      orderBy: { id: 'desc' },
      include: {
        responder: { select: assignmentResponderSelect },
      },
    }),
    loadRequest(numericRequestId),
  ]);
  if (!assignment || !request) return;

  const payload = {
    requestId: request.id,
    responderId: numericResponderId,
    assignment: {
      id: assignment.id,
      requestId: assignment.requestId,
      responderId: assignment.responderId,
      status: assignment.status,
      acceptedAt: assignment.acceptedAt,
      endedAt: assignment.endedAt,
      createdAt: assignment.createdAt,
      updatedAt: assignment.updatedAt,
      responder: assignment.responder
        ? {
            id: assignment.responder.id,
            name: assignment.responder.name,
            phone: assignment.responder.phone,
            responderStatus: assignment.responder.responderStatus,
            location: assignment.responder.location,
            latitude: assignment.responder.latitude,
            longitude: assignment.responder.longitude,
            lastActiveAt: assignment.responder.lastActiveAt,
          }
        : null,
    },
    assignments: (request.assignments || []).map((row) => ({
      id: row.id,
      requestId: row.requestId,
      responderId: row.responderId,
      status: row.status,
      acceptedAt: row.acceptedAt,
      endedAt: row.endedAt,
      responder: row.responder
        ? {
            id: row.responder.id,
            name: row.responder.name,
            phone: row.responder.phone,
            responderStatus: row.responder.responderStatus,
          }
        : null,
    })),
    request: requestPayload(request),
  };

  emitToRooms('responder.assigned', payload, [
    rooms.user(numericResponderId),
    rooms.request(request.id),
    rooms.user(request.requesterId),
    rooms.admins,
  ]);
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
  emitResponderAssigned,
  emitResponderAvailability,
  requestPayload,
};
