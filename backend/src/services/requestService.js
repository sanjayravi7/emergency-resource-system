const prisma = require('../config/prisma');
const {
  validateEmergencyRequestInput,
  normalizeRequiredResources,
} = require('../validators/requestValidator');
const { runSerializableTransaction } = require('./transactionService');
const {
  ACTIVE_REQUEST_STATUSES,
  JOINABLE_REQUEST_STATUSES,
  UNFINISHED_ALLOCATION_STATUSES,
  computeOutstandingByResource,
  syncRequestStatus,
  syncResponderAvailability,
  syncResponderAvailabilityForRequest,
} = require('./lifecycleService');
const {
  emitAllocationsForRequest,
  emitRequestCreated,
  emitRequestUpdated,
  emitResponderAssigned,
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
  // Relation name is responderAssignments on the model; the API/JSON shape is
  // built below so payloads stay additive.
  assignments: {
    include: {
      responder: { select: responderSelect },
    },
  },
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

/**
 * Normalize a capability row from either of the two shapes the services read:
 * the locked raw rows inside acceptance (`resourceIsActive`/`resourceMode`
 * columns) or a plain `responderResource.findMany` row (nested `resource`).
 * Mode-aware matching never depends on the row shape.
 */
function normalizeCapability(row) {
  if (!row) return null;
  if (row.resourceMode !== undefined) {
    return {
      resourceId: row.resourceId,
      isEnabled: row.isEnabled,
      resourceIsActive: row.resourceIsActive,
      mode: row.resourceMode,
      status: row.status,
      availableQuantity: row.availableQuantity,
    };
  }
  return {
    resourceId: row.resourceId,
    isEnabled: row.isEnabled,
    resourceIsActive: row.resource ? row.resource.isActive : false,
    mode: row.resource ? row.resource.mode : undefined,
    status: row.status,
    availableQuantity: row.availableQuantity,
  };
}

/**
 * PARTIAL capability matching (multi-responder dispatch).
 *
 * A responder qualifies for an emergency when at least one required resource
 * line still has outstanding quantity AND is servable by that responder under
 * the existing RESOURCE MODE rules:
 *   - SERVICE: enabled capability + active catalog resource (quantity never
 *     gates a reusable capability)
 *   - CONSUMABLE: enabled capability + active catalog resource + AVAILABLE
 *     stock status + at least one unit of real inventory
 *
 * A responder never needs to cover every required resource. Returns the
 * servable lines so callers can also report what remains.
 */
function findServableRequiredResources(requiredRows, outstandingByResource, capabilityRows) {
  const capabilities = (capabilityRows || [])
    .map(normalizeCapability)
    .filter(Boolean);

  const servable = [];
  for (const required of requiredRows) {
    const outstanding = outstandingByResource.get(required.resourceId) ?? 0;
    if (outstanding <= 0) continue;

    const capability = capabilities.find(
      (candidate) => candidate.resourceId === required.resourceId
    );
    if (!capability || !capability.isEnabled || !capability.resourceIsActive) {
      continue;
    }

    if (capability.mode === 'SERVICE') {
      servable.push({ resourceId: required.resourceId, outstanding });
      continue;
    }

    if (
      capability.status === 'AVAILABLE' &&
      capability.availableQuantity > 0
    ) {
      servable.push({
        resourceId: required.resourceId,
        outstanding: Math.min(outstanding, capability.availableQuantity),
      });
    }
  }
  return servable;
}

exports.findServableRequiredResources = findServableRequiredResources;

function normalizeOptionalDescription(value) {
  // Description is optional: blank input is represented consistently as SQL
  // NULL, while meaningful text is preserved exactly as supplied.
  return typeof value === 'string' && value.trim().length > 0 ? value : null;
}

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
      description: normalizeOptionalDescription(data.description),
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

  const { cancelled, syncedResponderIds } =
    await runSerializableTransaction(async (tx) => {
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
    }

    const cancelled = await tx.emergencyRequest.update({
      where: { id: requestId },
      data: { status: 'CANCELLED' },
      include: requestInclude,
    });

    // Availability is request-scoped: cancelling releases every responder
    // attached to this request - including assignment holders who never
    // created an allocation (they are not in the candidates loop above).
    const syncedResponderIds = await syncResponderAvailabilityForRequest(
      tx,
      requestId
    );

    return { cancelled, syncedResponderIds };
  });

  await emitAfterCommit(async () => {
    await emitRequestUpdated(requestId);
    await emitAllocationsForRequest(requestId);
    for (const responderId of syncedResponderIds) {
      await emitResponderAvailability(responderId);
    }
  });

  return cancelled;
};

exports.getAllRequests = async () =>
  prisma.emergencyRequest.findMany({
    include: requestInclude,
    orderBy: { createdAt: 'desc' },
  });

// ResponderAssignment is authoritative, but the legacy acceptedById rows and
// the "allocated without accepting" flow are deliberately still returned so
// no existing workload disappears from the responder board. findMany already
// yields each request exactly once.
exports.getAssignedRequestsForResponder = async (responderId) => {
  const numericResponderId = Number(responderId);
  return prisma.emergencyRequest.findMany({
    where: {
      OR: [
        {
          assignments: {
            some: { responderId: numericResponderId, status: 'ACTIVE' },
          },
        },
        {
          allocations: {
            some: {
              responderId: numericResponderId,
              status: { in: UNFINISHED_ALLOCATION_STATUSES },
            },
          },
        },
        { acceptedById: numericResponderId },
      ],
    },
    include: requestInclude,
    orderBy: { createdAt: 'desc' },
  });
};

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

  // One active emergency at a time. ResponderAssignment is authoritative;
  // the acceptedById lookup is the legacy fallback and can only exclude more,
  // never less.
  const [activeAssignment, legacyActiveEmergency] = await Promise.all([
    prisma.responderAssignment.findFirst({
      where: {
        responderId: numericResponderId,
        status: 'ACTIVE',
        request: { status: { in: ACTIVE_REQUEST_STATUSES } },
      },
      select: { requestId: true },
    }),
    prisma.emergencyRequest.findFirst({
      where: {
        acceptedById: numericResponderId,
        status: { in: ACTIVE_REQUEST_STATUSES },
        // Legacy pairs only: assignment rows are authoritative for their
        // own (request, responder) pair.
        assignments: { none: { responderId: numericResponderId } },
      },
      select: { id: true },
    }),
  ]);
  if (activeAssignment || legacyActiveEmergency) return [];

  // A capability must explicitly be enabled. Joining the resource catalog
  // ensures a disabled/inactive catalog resource can never match.
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

  // Multi-responder dispatch: an emergency stays visible to OTHER compatible
  // responders while it is active and still has outstanding work, even after
  // the first responder accepted it. Requests this responder is already
  // assigned to (or is the legacy lead of) are excluded. Note the explicit
  // NULL branch: Prisma's `not` alone would drop unaccepted (NULL lead)
  // emergencies entirely under SQL three-valued logic.
  const requests = await prisma.emergencyRequest.findMany({
    where: {
      status: { in: JOINABLE_REQUEST_STATUSES },
      OR: [
        { acceptedById: null },
        { acceptedById: { not: numericResponderId } },
      ],
      assignments: {
        none: {
          responderId: numericResponderId,
          status: 'ACTIVE',
        },
      },
    },
    include: requestInclude,
    orderBy: [{ priority: 'desc' }, { createdAt: 'asc' }],
  });

  return requests.filter((request) => {
    if (!request.requiredResources.length) return false;

    const outstandingByResource = computeOutstandingByResource(
      request.requiredResources,
      request.allocations
    );

    return (
      findServableRequiredResources(
        request.requiredResources,
        outstandingByResource,
        responderResources
      ).length > 0
    );
  });
};

exports.acceptEmergencyRequest = async (responderId, requestId) => {
  const numericResponderId = Number(responderId);
  const numericRequestId = Number(requestId);
  if (!Number.isInteger(numericRequestId) || numericRequestId <= 0) {
    throw new Error('Request not found');
  }

  const acceptedRequest = await runSerializableTransaction(async (tx) => {
    // Retain explicit row locks for acceptance. The request lock serializes
    // every responder racing to join this emergency; the user lock serializes
    // two different requests racing to be accepted by one responder.
    const lockedRequests = await tx.$queryRaw`
      SELECT id, status, "acceptedById"
      FROM "EmergencyRequest"
      WHERE id = ${numericRequestId}
      FOR UPDATE
    `;
    const requestRow = lockedRequests[0];
    if (!requestRow) throw new Error('Request not found');

    // Multi-responder acceptance: any active, non-terminal request may gain
    // an additional responder. Only the terminal states are closed.
    if (requestRow.status === 'CANCELLED') {
      throw new Error('Request has already been cancelled');
    }
    if (requestRow.status === 'COMPLETED') {
      throw new Error('Request has already been completed');
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

    // One active emergency per responder (existing business rule). The
    // assignment table is authoritative; acceptedById is the legacy
    // fallback. This request itself is excluded - joining it again is the
    // duplicate case handled below, not a conflict.
    const [conflictingAssignment, conflictingLegacyEmergency] =
      await Promise.all([
        tx.responderAssignment.findFirst({
          where: {
            responderId: numericResponderId,
            status: 'ACTIVE',
            request: {
              status: { in: ACTIVE_REQUEST_STATUSES },
              id: { not: numericRequestId },
            },
          },
          select: { id: true },
        }),
        tx.emergencyRequest.findFirst({
          where: {
            acceptedById: numericResponderId,
            status: { in: ACTIVE_REQUEST_STATUSES },
            id: { not: numericRequestId },
            // Legacy pairs only: once an assignment row exists for this
            // responder on that request, the table alone decides.
            assignments: { none: { responderId: numericResponderId } },
          },
          select: { id: true },
        }),
      ]);
    if (conflictingAssignment || conflictingLegacyEmergency) {
      throw new Error('Responder already has an active emergency');
    }

    // Duplicate membership on THIS request: application-level check first.
    // The database unique constraint on (requestId, responderId) is the final
    // safety net and is mapped to the same business error below. A legacy
    // lead without any assignment row also counts as assigned; a pair whose
    // row was ENDED is left to the constraint (re-joining ended assignments
    // is a later-phase transition).
    const existingPairRow = await tx.responderAssignment.findFirst({
      where: {
        requestId: numericRequestId,
        responderId: numericResponderId,
      },
      select: { id: true, status: true },
    });
    if (
      (existingPairRow && existingPairRow.status === 'ACTIVE') ||
      (!existingPairRow && requestRow.acceptedById === numericResponderId)
    ) {
      throw new Error('Responder is already assigned to this request');
    }

    const requiredResources = await tx.requestResource.findMany({
      where: { requestId: numericRequestId },
      select: { resourceId: true, quantity: true },
    });
    if (!requiredResources.length) {
      throw new Error('Request has no required resource');
    }

    // Outstanding quantity reuses the allocation service's definition of
    // "active allocation" so acceptance and allocation can never disagree
    // about how much work remains.
    const activeAllocations = await tx.allocation.findMany({
      where: {
        requestId: numericRequestId,
        status: { not: 'CANCELLED' },
      },
      select: { resourceId: true, quantity: true, status: true },
    });
    const outstandingByResource = computeOutstandingByResource(
      requiredResources,
      activeAllocations
    );

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

    // PARTIAL capability matching: the responder needs at least one required
    // resource line that still has outstanding quantity and that they can
    // serve under the existing mode rules. Full coverage is NOT required -
    // other responders may cover the remaining lines.
    const servable = findServableRequiredResources(
      requiredResources,
      outstandingByResource,
      responderResources
    );
    if (!servable.length) {
      throw new Error(
        'Responder has no compatible resource with outstanding quantity'
      );
    }

    // First assignment becomes the lead responder. acceptedById is never
    // overwritten by later assignments and is never cleared when one ends.
    const activeAssignmentCount = await tx.responderAssignment.count({
      where: { requestId: numericRequestId, status: 'ACTIVE' },
    });
    const isFirstAssignment =
      activeAssignmentCount === 0 && !requestRow.acceptedById;

    // One timestamp per acceptance: the assignment row and (for the first
    // acceptance) the request row describe the same event.
    const acceptedAt = new Date();

    let assignment;
    try {
      assignment = await tx.responderAssignment.create({
        data: {
          requestId: numericRequestId,
          responderId: numericResponderId,
          status: 'ACTIVE',
          acceptedAt,
        },
      });
    } catch (error) {
      // P2002 = unique (requestId, responderId) violation from a concurrent
      // accept that committed between our check and this insert. Surface it
      // as the same business conflict instead of leaking a Prisma error.
      if (error.code === 'P2002') {
        throw new Error('Responder is already assigned to this request');
      }
      throw error;
    }

    if (isFirstAssignment) {
      await tx.emergencyRequest.update({
        where: { id: numericRequestId },
        data: {
          acceptedById: numericResponderId,
          acceptedAt,
        },
      });
    }

    await tx.user.update({
      where: { id: numericResponderId },
      data: { lastActiveAt: new Date() },
    });

    // Derive the request status from persisted state exactly as the rest of
    // the lifecycle does: first acceptance moves PENDING -> ACCEPTED, later
    // acceptances keep the existing active status (never reset to PENDING).
    await syncRequestStatus(tx, numericRequestId);
    await syncResponderAvailability(tx, numericResponderId);

    // The response contract is unchanged: the updated request row, now also
    // carrying its assignments through requestInclude.
    return tx.emergencyRequest.findUnique({
      where: { id: numericRequestId },
      include: requestInclude,
    });
  });

  await emitAfterCommit(async () => {
    await emitRequestUpdated(numericRequestId, [numericResponderId]);
    // Per-responder assignment confirmation for multi-responder dispatch:
    // the assigned responder receives their own assignment, while the
    // requester, request room, and admins receive the full assignments[]
    // state. Emitted only after the acceptance transaction committed.
    await emitResponderAssigned(numericRequestId, numericResponderId);
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
