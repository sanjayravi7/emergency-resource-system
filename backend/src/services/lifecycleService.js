const ACTIVE_REQUEST_STATUSES = [
  'ACCEPTED',
  'IN_PROGRESS',
  'PARTIALLY_ALLOCATED',
];

const UNFINISHED_ALLOCATION_STATUSES = ['RESERVED', 'DISPATCHED'];

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

  const [activeEmergency, unfinishedAllocation] = await Promise.all([
    tx.emergencyRequest.findFirst({
      where: {
        acceptedById: numericResponderId,
        status: { in: ACTIVE_REQUEST_STATUSES },
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

  if (activeEmergency || unfinishedAllocation) {
    responderStatus = 'BUSY';
  } else if (responder.isActive) {
    const usableEnabledResource = await tx.responderResource.findFirst({
      where: {
        responderId: numericResponderId,
        isEnabled: true,
        availableQuantity: { gt: 0 },
      },
      select: { id: true },
    });

    if (usableEnabledResource) responderStatus = 'AVAILABLE';
  }

  return tx.user.update({
    where: { id: numericResponderId },
    data: { responderStatus },
  });
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
    },
  });

  if (!request || request.status === 'CANCELLED') return request;

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

  if (status === request.status) return request;

  return tx.emergencyRequest.update({
    where: { id: numericRequestId },
    data: { status },
  });
}

module.exports = {
  ACTIVE_REQUEST_STATUSES,
  UNFINISHED_ALLOCATION_STATUSES,
  syncResponderAvailability,
  syncRequestStatus,
};
