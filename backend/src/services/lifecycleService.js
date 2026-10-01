const ACTIVE_REQUEST_STATUSES = [
  'ACCEPTED',
  'IN_PROGRESS',
  'PARTIALLY_ALLOCATED',
];

const UNFINISHED_ALLOCATION_STATUSES = ['RESERVED', 'DISPATCHED'];

// Statuses from which a responder may still join an emergency. PENDING is the
// classic case; the ACTIVE_* statuses are joinable for additional responders
// under multi-responder dispatch. CANCELLED/COMPLETED are terminal and never
// joinable.
const JOINABLE_REQUEST_STATUSES = ['PENDING', ...ACTIVE_REQUEST_STATUSES];

/**
 * Single source of truth for "how much of a required resource is still
 * unallocated". Active allocations are every non-CANCELLED allocation, which
 * is exactly the definition the allocation service enforces when it guards
 * against over-allocation. Both acceptance (partial capability matching) and
 * allocation creation consume this helper so the two flows can never disagree.
 *
 * @returns Map<resourceId, outstanding quantity> (only for the required rows;
 * values may be <= 0 when the requirement is already fully allocated)
 */
function computeOutstandingByResource(requiredRows, allocationRows) {
  const outstandingByResource = new Map();
  for (const required of requiredRows) {
    outstandingByResource.set(required.resourceId, required.quantity);
  }
  for (const allocation of allocationRows || []) {
    if (allocation.status === 'CANCELLED') continue;
    const current = outstandingByResource.get(allocation.resourceId);
    if (current === undefined) continue;
    outstandingByResource.set(allocation.resourceId, current - allocation.quantity);
  }
  return outstandingByResource;
}

/**
 * Recompute the responder's operational status from persisted work, rather
 * than inferring it from a single allocation or resource row. The caller owns
 * the transaction so status and lifecycle mutations remain atomic.
 */
async function syncResponderAvailability(tx, responderId) {
  const numericResponderId = Number(responderId);

  const responder = await tx.user.findUnique({
    where: { id: numericResponderId },
    select: {
      id: true,
      role: true,
      isActive: true,
    },
  });

  if (!responder || responder.role !== 'RESPONDER') return null;

  // ResponderAssignment is the authoritative assignment relationship. The
  // acceptedById lookup is kept as a legacy fallback for rows written before
  // assignments existed (or set up directly in the database): it only counts
  // when NO assignment row exists for that (request, responder) pair - once a
  // pair has assignment data, the table alone decides. It can only add BUSY,
  // never hide active work.
  const [activeAssignment, legacyAcceptedEmergency, unfinishedAllocation] =
    await Promise.all([
      tx.responderAssignment.findFirst({
        where: {
          responderId: numericResponderId,
          status: 'ACTIVE',
          request: { status: { in: ACTIVE_REQUEST_STATUSES } },
        },
        select: { id: true },
      }),
      tx.emergencyRequest.findFirst({
        where: {
          acceptedById: numericResponderId,
          status: { in: ACTIVE_REQUEST_STATUSES },
          assignments: { none: { responderId: numericResponderId } },
        },
        select: { id: true },
      }),
      tx.allocation.findFirst({
        where: {
          responderId: numericResponderId,
          status: { in: UNFINISHED_ALLOCATION_STATUSES },
        },
        select: { id: true },
      }),
    ]);

  let responderStatus = 'OFFLINE';

  if (activeAssignment || legacyAcceptedEmergency || unfinishedAllocation) {
    responderStatus = 'BUSY';
  } else if (responder.isActive) {
    // Emergency-category readiness is independent from physical inventory.
    // A responder with an enabled help type can stay AVAILABLE even when the
    // Resource catalog is empty or all carried inventory is unavailable.
    const helpTypes = await tx.responderHelpType.findMany({
      where: { responderId: numericResponderId },
      select: { enabled: true },
    });

    if (helpTypes.some((row) => row.enabled)) {
      responderStatus = 'AVAILABLE';
    } else if (helpTypes.length === 0) {
      // Transitional compatibility for responders created before help types
      // existed. As soon as the responder saves the readiness form (including
      // an empty selection), help-type rows become authoritative forever.
      const legacyUsableResource = await tx.responderResource.findFirst({
        where: {
          AND: [
            { responderId: numericResponderId },
            { isEnabled: true },
            { resource: { isActive: true } },
            {
              OR: [
                { resource: { mode: 'SERVICE' } },
                { availableQuantity: { gt: 0 } },
              ],
            },
          ],
        },
        select: { id: true },
      });
      if (legacyUsableResource) responderStatus = 'AVAILABLE';
    }
  }

  return tx.user.update({
    where: { id: numericResponderId },
    data: { responderStatus },
  });
}

/**
 * Re-derive availability for every responder attached to a request: the lead
 * responder (acceptedById), every assignment holder (ACTIVE *or* ENDED), and
 * every responder holding an allocation row on the request (any allocation
 * status - a request-wide cancellation or a completion can change the BUSY
 * basis of responders who did not act in the current transaction).
 *
 * ENDED assignment holders are deliberately included: terminal transitions
 * (cancel / complete) END every ACTIVE assignment in the SAME transaction
 * BEFORE calling this helper, so filtering by ACTIVE here would miss exactly
 * the non-lead responders that were just released and leave them stuck BUSY
 * (and without a realtime availability emit). Re-syncing is a pure
 * derived-state recompute, so syncing a superset is always safe: it can only
 * remove stale statuses, never invent work.
 *
 * @param {*} tx transaction/Prisma client owning the mutation
 * @param {number|string} requestId request whose attached responders re-sync
 * @param {Array<number|string>} extraResponderIds additional responders to
 *        include (the responder acting in the current transaction)
 * @returns {Promise<number[]>} sorted responder ids that were re-synced, so
 *          callers can keep realtime availability events consistent with the
 *          committed database state
 */
async function syncResponderAvailabilityForRequest(
  tx,
  requestId,
  extraResponderIds = []
) {
  const numericRequestId = Number(requestId);
  const responderIds = new Set(
    [...extraResponderIds]
      .map(Number)
      .filter((id) => Number.isInteger(id) && id > 0)
  );

  const request = await tx.emergencyRequest.findUnique({
    where: { id: numericRequestId },
    select: { acceptedById: true },
  });
  if (request && request.acceptedById) {
    responderIds.add(Number(request.acceptedById));
  }

  const [assignmentRows, allocationRows] = await Promise.all([
    tx.responderAssignment.findMany({
      where: { requestId: numericRequestId },
      select: { responderId: true },
    }),
    tx.allocation.findMany({
      where: { requestId: numericRequestId },
      select: { responderId: true },
    }),
  ]);

  for (const row of assignmentRows) {
    responderIds.add(Number(row.responderId));
  }
  for (const row of allocationRows) {
    responderIds.add(Number(row.responderId));
  }

  const syncedResponderIds = [...responderIds].sort((a, b) => a - b);
  for (const responderId of syncedResponderIds) {
    await syncResponderAvailability(tx, responderId);
  }
  return syncedResponderIds;
}

/**
 * Derive request status from allocation delivery, never merely from a
 * reservation. A cancelled request remains terminal. For each required
 * resource we retain the complete lifecycle totals so the rules are explicit
 * and safe for multi-resource emergencies.
 */
async function syncRequestStatus(tx, requestId) {
  const numericRequestId = Number(requestId);
  const request = await tx.emergencyRequest.findUnique({
    where: { id: numericRequestId },
    include: {
      requiredResources: true,
      allocations: {
        select: {
          resourceId: true,
          quantity: true,
          status: true,
        },
      },
      assignments: {
        select: {
          status: true,
        },
      },
    },
  });

  if (
    !request ||
    request.status === 'CANCELLED' ||
    request.status === 'COMPLETED'
  ) {
    return request;
  }

  if (request.requiredResources.length === 0) {
    if (request.status === 'IN_PROGRESS') {
      return request;
    }
    const hasActiveAssignment =
      request.assignments &&
      request.assignments.some((assignment) => assignment.status === 'ACTIVE');
    const isAccepted = Boolean(hasActiveAssignment || request.acceptedById);
    const targetStatus = isAccepted ? 'ACCEPTED' : 'PENDING';
    if (targetStatus === request.status) return request;
    return tx.emergencyRequest.update({
      where: { id: numericRequestId },
      data: { status: targetStatus },
    });
  }

  const quantitiesByResource = new Map();
  for (const required of request.requiredResources) {
    quantitiesByResource.set(required.resourceId, {
      required: required.quantity,
      reservedOrDispatched: 0,
      delivered: 0,
      cancelled: 0,
    });
  }

  let hasStartedAllocation = false;
  let hasDeliveredQuantity = false;

  for (const allocation of request.allocations) {
    const totals = quantitiesByResource.get(allocation.resourceId);
    if (!totals) continue;

    if (allocation.status === 'RESERVED' || allocation.status === 'DISPATCHED') {
      totals.reservedOrDispatched += allocation.quantity;
      hasStartedAllocation = true;
    } else if (allocation.status === 'DELIVERED') {
      totals.delivered += allocation.quantity;
      hasStartedAllocation = true;
      hasDeliveredQuantity = true;
    } else if (allocation.status === 'CANCELLED') {
      totals.cancelled += allocation.quantity;
    }
  }

  const resourceTotals = [...quantitiesByResource.values()];
  const allDelivered =
    resourceTotals.length > 0 &&
    resourceTotals.every((totals) => totals.delivered >= totals.required);

  let status;
  if (allDelivered) {
    status = 'COMPLETED';
  } else if (hasDeliveredQuantity) {
    // At least one resource has reached the requester, but the complete
    // required set has not. Reserved or dispatched sibling allocations still
    // keep the responder BUSY through syncResponderAvailability.
    status = 'PARTIALLY_ALLOCATED';
  } else if (hasStartedAllocation) {
    status = 'IN_PROGRESS';
  } else if (request.acceptedById) {
    status = 'ACCEPTED';
  } else {
    status = 'PENDING';
  }

  // Responder-driven progress is authoritative for resource-bearing requests
  // as well: START RESPONSE moves ACCEPTED -> IN_PROGRESS without any
  // Allocation rows, so an allocation-derived recompute (another responder
  // joining, a legacy allocation being cancelled, ...) must never regress an
  // IN_PROGRESS emergency back to ACCEPTED/PENDING. Legacy allocation
  // delivery may still advance it to PARTIALLY_ALLOCATED / COMPLETED.
  if (
    request.status === 'IN_PROGRESS' &&
    (status === 'ACCEPTED' || status === 'PENDING')
  ) {
    return request;
  }

  if (status === 'COMPLETED') {
    // Completion and assignment cleanup share the caller's transaction (the
    // allocation delivery transaction in the normal path).
    await tx.responderAssignment.updateMany({
      where: { requestId: numericRequestId, status: 'ACTIVE' },
      data: { status: 'ENDED', endedAt: new Date() },
    });
  }

  if (status === request.status) return request;

  return tx.emergencyRequest.update({
    where: { id: numericRequestId },
    data: { status },
  });
}

module.exports = {
  ACTIVE_REQUEST_STATUSES,
  JOINABLE_REQUEST_STATUSES,
  UNFINISHED_ALLOCATION_STATUSES,
  computeOutstandingByResource,
  syncResponderAvailability,
  syncResponderAvailabilityForRequest,
  syncRequestStatus,
};
