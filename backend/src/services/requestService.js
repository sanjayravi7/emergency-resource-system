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
  emitResponderLocationStop,
} = require('../realtime/eventEmitters');
const { getIO, rooms } = require('../realtime/socketEvents');
const pushNotificationService = require('./pushNotificationService');
const { categoryForEmergencyType } = require('../domain/emergencyCategories');

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
  //
  // Creation and notification are separate concerns by design: this block
  // runs AFTER the emergency is durably stored, and emitAfterCommit swallows
  // every error, so zero online responders, a Socket.IO fault or an FCM
  // outage can never reject or roll back an already-committed emergency. The
  // request simply stays PENDING until a compatible responder comes online
  // and reads GET /api/requests/compatible.
  await emitAfterCommit(async () => {
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

    // Realtime notification: only compatible responders currently connected
    // through Socket.IO receive the new-emergency event.
    const io = getIO();
    if (io) {
      await emitRequestCreated(created, compatibleResponderIds);
    }

    // FCM push covers compatible responders whose app is backgrounded or not
    // maintaining a Socket.IO connection. Devices with a live socket are
    // skipped when their connection state is known; on any doubt a responder
    // is treated as offline (a duplicate push is safer than a missed one).
    const onlineResponderIds = new Set();
    if (io) {
      for (const responderId of compatibleResponderIds) {
        try {
          const sockets = await io.in(rooms.user(responderId)).allSockets();
          if (sockets.size > 0) onlineResponderIds.add(Number(responderId));
        } catch {
          // Unknown connection state: leave the responder out of the online
          // set so they still receive the push.
        }
      }
    }
    await pushNotificationService.notifyRespondersOfNewEmergency(
      created,
      compatibleResponderIds,
      onlineResponderIds
    );
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

async function cancelUnfinishedAllocations(tx, requestId) {
  const candidates = await tx.allocation.findMany({
    where: {
      requestId,
      status: { in: ['RESERVED', 'DISPATCHED'] },
    },
    select: { id: true, responderId: true },
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

    // SERVICE capabilities never decrement or restore inventory. Unfinished
    // CONSUMABLE reservations return exactly the quantity they held.
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

  return [...new Set(candidates.map((row) => row.responderId))];
}

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

  const { cancelled, syncedResponderIds, terminalResponderIds } =
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

    const activeAssignments = await tx.responderAssignment.findMany({
      where: { requestId, status: 'ACTIVE' },
      select: { responderId: true },
    });
    const allocationResponderIds = await cancelUnfinishedAllocations(
      tx,
      requestId
    );
    const terminalResponderIds = [
      ...new Set([
        ...allocationResponderIds,
        ...activeAssignments.map((row) => row.responderId),
      ]),
    ];

    // Terminal cleanup is part of the same transaction as the request
    // transition. acceptedById is deliberately untouched for history.
    await tx.responderAssignment.updateMany({
      where: { requestId, status: 'ACTIVE' },
      data: { status: 'ENDED', endedAt: new Date() },
    });

    const cancelled = await tx.emergencyRequest.update({
      where: { id: requestId },
      data: { status: 'CANCELLED' },
      include: requestInclude,
    });

    // Availability is request-scoped: cancelling releases every responder
    // attached to this request - including assignment holders who never
    // created an allocation.
    const syncedResponderIds = await syncResponderAvailabilityForRequest(
      tx,
      requestId
    );

    return { cancelled, syncedResponderIds, terminalResponderIds };
  });

  await emitAfterCommit(async () => {
    await emitRequestUpdated(requestId, terminalResponderIds);
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

/**
 * Safe responder overview used by the legacy GET /api/requests route.
 * Responders may see only work they already participate in or requests the
 * compatibility contract currently allows them to discover. The old
 * unfiltered implementation exposed every requester's private emergency.
 */
exports.getVisibleRequestsForResponder = async (responderId) => {
  const [assigned, compatible] = await Promise.all([
    exports.getAssignedRequestsForResponder(responderId),
    exports.getCompatibleRequestsForResponder(responderId),
  ]);
  const byId = new Map();
  for (const request of [...assigned, ...compatible]) byId.set(request.id, request);
  return [...byId.values()].sort((left, right) =>
    right.createdAt.getTime() - left.createdAt.getTime()
  );
};

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
        {
          acceptedById: numericResponderId,
          assignments: { none: { responderId: numericResponderId } },
          status: { notIn: ['COMPLETED', 'CANCELLED'] },
        },
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

  // Help types are the category/eligibility layer. They deliberately do not
  // join Resource or ResponderResource: an empty catalog or zero inventory
  // must not hide a category-compatible emergency.
  const helpTypes = await prisma.responderHelpType.findMany({
    where: { responderId: numericResponderId },
    select: { category: true, enabled: true },
  });
  const enabledCategories = new Set(
    helpTypes.filter((row) => row.enabled).map((row) => row.category)
  );
  if (helpTypes.length > 0 && !enabledCategories.size) return [];

  // Pre-help-type responders keep their prior resource-based discovery until
  // they first save readiness. This is a migration bridge only: once any help
  // rows exist, categories above are authoritative even if inventory changes.
  const legacyResponderResources = helpTypes.length === 0
    ? await prisma.responderResource.findMany({
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
      })
    : [];

  // Multi-responder dispatch: an emergency stays visible to OTHER compatible
  // responders while it is active and still has outstanding work, even after
  // the first responder accepted it. Requests this responder is already
  // assigned to (or is the legacy lead of) are excluded. Note the explicit
  // NULL branch: Prisma's `not` alone would drop unaccepted (NULL lead)
  // emergencies entirely under SQL three-valued logic.
  const requests = await prisma.emergencyRequest.findMany({
    where: {
      status: { in: JOINABLE_REQUEST_STATUSES },
      // acceptedById is historical lead metadata and must not block a
      // responder whose prior assignment is ENDED from rejoining. Active
      // membership (and legacy pairs with no assignment row) are handled
      // explicitly above.
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
    if (helpTypes.length > 0) {
      return enabledCategories.has(
        categoryForEmergencyType(request.emergencyType)
      );
    }

    // Legacy resource matching is intentionally isolated to responders with
    // no help-type rows. It disappears permanently after their first save.
    if (!request.requiredResources.length) return false;
    const outstandingByResource = computeOutstandingByResource(
      request.requiredResources,
      request.allocations
    );
    return findServableRequiredResources(
      request.requiredResources,
      outstandingByResource,
      legacyResponderResources
    ).length > 0;
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
      SELECT id, status, "acceptedById", "emergencyType"
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

    // Re-check category eligibility while the responder row is locked. The
    // readiness update and acceptance therefore cannot grant access based on
    // Resource inventory or a stale client-side list.
    const requestCategory = categoryForEmergencyType(requestRow.emergencyType);
    const configuredHelpTypes = await tx.responderHelpType.findMany({
      where: { responderId: numericResponderId },
      select: { category: true, enabled: true },
    });
    const hasMatchingHelpType = configuredHelpTypes.some(
      (row) => row.enabled && row.category === requestCategory
    );
    if (configuredHelpTypes.length > 0 && !hasMatchingHelpType) {
      throw new Error('Responder does not have a compatible help type');
    }

    const requiredResources = await tx.requestResource.findMany({
      where: { requestId: numericRequestId },
      select: { resourceId: true, quantity: true },
    });
    if (
      configuredHelpTypes.length === 0 &&
      !requiredResources.length &&
      !hasMatchingHelpType
    ) {
      throw new Error('Responder does not have a compatible help type');
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
    const reactivatingAssignment =
      existingPairRow && existingPairRow.status === 'ENDED';

    if (requiredResources.length) {
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

      // Lock all inventory rows before the resource compatibility re-check so
      // changes made after discovery cannot race acceptance.
      const responderResources = await tx.$queryRaw`
        SELECT rr.id, rr."resourceId", rr."availableQuantity", rr.status,
               rr."isEnabled", resource."isActive" AS "resourceIsActive",
               resource."mode" AS "resourceMode"
        FROM "ResponderResource" AS rr
        INNER JOIN "Resource" AS resource ON resource.id = rr."resourceId"
        WHERE rr."responderId" = ${numericResponderId}
        FOR UPDATE OF rr, resource
      `;

      // Resource-bearing requests retain the existing mode, quantity, active
      // catalog and outstanding-allocation checks at acceptance time.
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
      // The unique pair row is intentionally reused when a responder rejoins.
      // This keeps the assignment history stable and makes concurrent rejoin
      // attempts serialize on the request lock rather than creating rows.
      assignment = reactivatingAssignment
        ? await tx.responderAssignment.update({
            where: { id: existingPairRow.id },
            data: { status: 'ACTIVE', endedAt: null, acceptedAt },
          })
        : await tx.responderAssignment.create({
            data: {
              requestId: numericRequestId,
              responderId: numericResponderId,
              status: 'ACTIVE',
              acceptedAt,
            },
          });
    } catch (error) {
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

/** End one assignment, with ownership enforced inside the locked transaction. */
exports.endResponderAssignment = async (actor, requestId, responderId = actor.id) => {
  const numericRequestId = Number(requestId);
  const numericResponderId = Number(responderId);
  if (actor.role !== 'ADMIN' && actor.role !== 'RESPONDER') {
    throw new Error('Only responders or admins may end assignments');
  }
  if (actor.role !== 'ADMIN' && Number(actor.id) !== numericResponderId) {
    throw new Error('You may only end your own assignment');
  }

  const result = await runSerializableTransaction(async (tx) => {
    const locked = await tx.$queryRaw`
      SELECT id, status FROM "EmergencyRequest" WHERE id = ${numericRequestId} FOR UPDATE
    `;
    if (!locked[0]) throw new Error('Request not found');
    const assignment = await tx.responderAssignment.findUnique({
      where: { requestId_responderId: { requestId: numericRequestId, responderId: numericResponderId } },
      select: { id: true, status: true },
    });
    if (!assignment) throw new Error('Assignment not found');
    if (assignment.status !== 'ACTIVE') throw new Error('Assignment has already ended');

    await tx.responderAssignment.update({
      where: { id: assignment.id },
      data: { status: 'ENDED', endedAt: new Date() },
    });
    const syncedResponderIds = await syncResponderAvailabilityForRequest(
      tx, numericRequestId, [numericResponderId]
    );
    const request = await tx.emergencyRequest.findUnique({
      where: { id: numericRequestId }, include: requestInclude,
    });
    return { request, syncedResponderIds };
  });

  await emitAfterCommit(async () => {
    await emitRequestUpdated(numericRequestId, [numericResponderId]);
    const stillParticipatesThroughAllocation = result.request.allocations.some(
      (allocation) =>
        allocation.responderId === numericResponderId &&
        UNFINISHED_ALLOCATION_STATUSES.includes(allocation.status)
    );
    if (!stillParticipatesThroughAllocation) {
      await emitResponderLocationStop(numericRequestId, numericResponderId);
    }
    for (const id of result.syncedResponderIds) await emitResponderAvailability(id);
  });
  return result.request;
};

exports.updateRequestStatus = async (requestId, status) => {
  const numericRequestId = Number(requestId);
  if (!['COMPLETED', 'CANCELLED'].includes(status)) {
    return prisma.emergencyRequest.update({ where: { id: numericRequestId }, data: { status } });
  }
  // Admin cancellation follows the exact requester cleanup transaction rather
  // than bypassing allocation cancellation/inventory restoration.
  if (status === 'CANCELLED') {
    const request = await prisma.emergencyRequest.findUnique({
      where: { id: numericRequestId },
      select: { requesterId: true },
    });
    if (!request) throw new Error('Request not found');
    return exports.cancelEmergencyRequest(request.requesterId, numericRequestId);
  }
  const result = await runSerializableTransaction(async (tx) => {
    await tx.$queryRaw`SELECT id FROM "EmergencyRequest" WHERE id = ${numericRequestId} FOR UPDATE`;
    const existing = await tx.emergencyRequest.findUnique({ where: { id: numericRequestId } });
    if (!existing) throw new Error('Request not found');
    const activeAssignments = await tx.responderAssignment.findMany({
      where: { requestId: numericRequestId, status: 'ACTIVE' },
      select: { responderId: true },
    });
    // Preserve the established admin force-completion contract while making
    // it a real terminal cleanup: unfinished work is cancelled, CONSUMABLE
    // inventory is restored, SERVICE quantities remain untouched, and every
    // ACTIVE assignment ends atomically. Naturally delivered allocations are
    // left DELIVERED by the helper.
    const allocationResponderIds = await cancelUnfinishedAllocations(
      tx,
      numericRequestId
    );
    await tx.responderAssignment.updateMany({
      where: { requestId: numericRequestId, status: 'ACTIVE' },
      data: { status: 'ENDED', endedAt: new Date() },
    });
    const updated = await tx.emergencyRequest.update({
      where: { id: numericRequestId },
      data: { status: 'COMPLETED' },
      include: requestInclude,
    });
    const syncedResponderIds = await syncResponderAvailabilityForRequest(tx, numericRequestId);
    return {
      updated,
      syncedResponderIds,
      terminalResponderIds: [
        ...new Set([
          ...allocationResponderIds,
          ...activeAssignments.map((row) => row.responderId),
        ]),
      ],
    };
  });
  await emitAfterCommit(async () => {
    await emitRequestUpdated(numericRequestId, result.terminalResponderIds);
    for (const id of result.syncedResponderIds) await emitResponderAvailability(id);
  });
  return result.updated;
};

exports.startEmergencyResponse = async (responderId, requestId) => {
  const numericResponderId = Number(responderId);
  const numericRequestId = Number(requestId);
  if (!Number.isInteger(numericRequestId) || numericRequestId <= 0) {
    throw new Error('Request not found');
  }

  const updatedRequest = await runSerializableTransaction(async (tx) => {
    const lockedRequests = await tx.$queryRaw`
      SELECT id, status, "acceptedById", "emergencyType"
      FROM "EmergencyRequest"
      WHERE id = ${numericRequestId}
      FOR UPDATE
    `;
    const requestRow = lockedRequests[0];
    if (!requestRow) throw new Error('Request not found');

    if (requestRow.status === 'CANCELLED') {
      throw new Error('Request has already been cancelled');
    }
    if (requestRow.status === 'COMPLETED') {
      throw new Error('Request has already been completed');
    }
    if (requestRow.status === 'IN_PROGRESS') {
      throw new Error('Request is already in progress');
    }
    if (requestRow.status !== 'ACCEPTED') {
      throw new Error('Request must be accepted before starting response');
    }

    const requiredResources = await tx.requestResource.findMany({
      where: { requestId: numericRequestId },
      select: { id: true },
    });
    if (requiredResources.length > 0) {
      throw new Error(
        'Cannot start response on request with required resources'
      );
    }

    const lockedResponders = await tx.$queryRaw`
      SELECT id, role, "isActive"
      FROM "User"
      WHERE id = ${numericResponderId}
      FOR UPDATE
    `;
    const responder = lockedResponders[0];
    if (!responder || responder.role !== 'RESPONDER') {
      throw new Error('Only responders can start emergency response');
    }
    if (!responder.isActive) {
      throw new Error('Responder is inactive');
    }

    const assignment = await tx.responderAssignment.findUnique({
      where: {
        requestId_responderId: {
          requestId: numericRequestId,
          responderId: numericResponderId,
        },
      },
      select: { id: true, status: true },
    });

    const isLead = requestRow.acceptedById === numericResponderId;
    const isAssigned =
      (assignment && assignment.status === 'ACTIVE') ||
      (isLead && !assignment);

    if (!isAssigned) {
      throw new Error('Unauthorized: Responder is not assigned to this request');
    }

    await tx.user.update({
      where: { id: numericResponderId },
      data: { lastActiveAt: new Date() },
    });

    const updated = await tx.emergencyRequest.update({
      where: { id: numericRequestId },
      data: { status: 'IN_PROGRESS' },
      include: requestInclude,
    });

    await syncResponderAvailability(tx, numericResponderId);

    return updated;
  });

  await emitAfterCommit(async () => {
    await emitRequestUpdated(numericRequestId, [numericResponderId]);
    await emitResponderAvailability(numericResponderId);
  });

  return updatedRequest;
};

exports.completeEmergencyResponse = async (responderId, requestId) => {
  const numericResponderId = Number(responderId);
  const numericRequestId = Number(requestId);
  if (!Number.isInteger(numericRequestId) || numericRequestId <= 0) {
    throw new Error('Request not found');
  }

  const { updated, syncedResponderIds, terminalResponderIds } =
    await runSerializableTransaction(async (tx) => {
      const lockedRequests = await tx.$queryRaw`
        SELECT id, status, "acceptedById", "emergencyType"
        FROM "EmergencyRequest"
        WHERE id = ${numericRequestId}
        FOR UPDATE
      `;
      const requestRow = lockedRequests[0];
      if (!requestRow) throw new Error('Request not found');

      if (requestRow.status === 'CANCELLED') {
        throw new Error('Request has already been cancelled');
      }
      if (requestRow.status === 'COMPLETED') {
        throw new Error('Request has already been completed');
      }
      if (requestRow.status !== 'IN_PROGRESS') {
        throw new Error('Request must be in progress to complete response');
      }

      const requiredResources = await tx.requestResource.findMany({
        where: { requestId: numericRequestId },
        select: { id: true },
      });
      if (requiredResources.length > 0) {
        throw new Error(
          'Cannot complete response on request with required resources'
        );
      }

      const lockedResponders = await tx.$queryRaw`
        SELECT id, role, "isActive"
        FROM "User"
        WHERE id = ${numericResponderId}
        FOR UPDATE
      `;
      const responder = lockedResponders[0];
      if (!responder || responder.role !== 'RESPONDER') {
        throw new Error('Only responders can complete emergency response');
      }
      if (!responder.isActive) {
        throw new Error('Responder is inactive');
      }

      const assignment = await tx.responderAssignment.findUnique({
        where: {
          requestId_responderId: {
            requestId: numericRequestId,
            responderId: numericResponderId,
          },
        },
        select: { id: true, status: true },
      });

      const isLead = requestRow.acceptedById === numericResponderId;
      const isAssigned =
        (assignment && assignment.status === 'ACTIVE') ||
        (isLead && !assignment);

      if (!isAssigned) {
        throw new Error(
          'Unauthorized: Responder is not assigned to this request'
        );
      }

      const activeAssignments = await tx.responderAssignment.findMany({
        where: { requestId: numericRequestId, status: 'ACTIVE' },
        select: { responderId: true },
      });

      await tx.responderAssignment.updateMany({
        where: { requestId: numericRequestId, status: 'ACTIVE' },
        data: { status: 'ENDED', endedAt: new Date() },
      });

      await tx.user.update({
        where: { id: numericResponderId },
        data: { lastActiveAt: new Date() },
      });

      const updated = await tx.emergencyRequest.update({
        where: { id: numericRequestId },
        data: { status: 'COMPLETED' },
        include: requestInclude,
      });

      const syncedResponderIds =
        await syncResponderAvailabilityForRequest(
          tx,
          numericRequestId,
          [numericResponderId]
        );

      const terminalResponderIds = [
        ...new Set([
          numericResponderId,
          ...activeAssignments.map((row) => row.responderId),
        ]),
      ];

      return { updated, syncedResponderIds, terminalResponderIds };
    });

  await emitAfterCommit(async () => {
    for (const id of terminalResponderIds) {
      await emitResponderLocationStop(numericRequestId, id);
    }
    await emitRequestUpdated(numericRequestId, terminalResponderIds);
    for (const id of syncedResponderIds) {
      await emitResponderAvailability(id);
    }
  });

  return updated;
};
