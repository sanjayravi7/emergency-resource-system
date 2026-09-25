const prisma = require('../config/prisma');
const { runSerializableTransaction } = require('./transactionService');
const {
  syncRequestStatus,
  syncResponderAvailability,
} = require('./lifecycleService');

exports.getAllocationsByResponder = async (responderId) => {
  return prisma.allocation.findMany({
    where: { responderId: Number(responderId) },
    include: {
      resource: {
        select: {
          id: true,
          name: true,
          type: true,
          unit: true,
        },
      },
      request: {
        select: {
          id: true,
          emergencyType: true,
          location: true,
          status: true,
          requester: { select: { id: true, name: true, phone: true } },
        },
      },
    },
    orderBy: { allocatedAt: 'desc' },
  });
};

function asPositiveInteger(value, field) {
  const number = Number(value);
  if (!Number.isInteger(number) || number <= 0) {
    throw new Error(`${field} must be a positive integer`);
  }
  return number;
}

async function lockAllocation(tx, allocationId) {
  const locked = await tx.$queryRaw`
    SELECT id, "requestId", "resourceId", "responderId", "responderResourceId",
           quantity, status
    FROM "Allocation"
    WHERE id = ${allocationId}
    FOR UPDATE
  `;

  return locked[0] || null;
}

async function lockResponderResource(tx, responderResourceId) {
  const locked = await tx.$queryRaw`
    SELECT id, "responderId", "resourceId", "totalQuantity", "availableQuantity",
           "isEnabled", status
    FROM "ResponderResource"
    WHERE id = ${responderResourceId}
    FOR UPDATE
  `;

  return locked[0] || null;
}

exports.createAllocation = async (responderId, data) => {
  const requestId = asPositiveInteger(data.requestId, 'requestId');
  const responderResourceId = asPositiveInteger(
    data.responderResourceId,
    'responderResourceId'
  );
  const resourceId = asPositiveInteger(data.resourceId, 'resourceId');
  const quantity = Number(data.quantity);
  if (!Number.isInteger(quantity) || quantity <= 0) {
    throw new Error('Quantity must be greater than 0');
  }

  return runSerializableTransaction(async (tx) => {
    // Lock the request first. This serializes remaining-quantity calculation
    // across allocations, including allocations from separate resource rows.
    const lockedRequests = await tx.$queryRaw`
      SELECT id, status, "acceptedById"
      FROM "EmergencyRequest"
      WHERE id = ${requestId}
      FOR UPDATE
    `;
    const requestRow = lockedRequests[0];

    if (
      !requestRow ||
      requestRow.status === 'CANCELLED' ||
      requestRow.status === 'COMPLETED'
    ) {
      throw new Error('Request is invalid or already closed');
    }

    // Keep SELECT FOR UPDATE protection for the inventory that will be spent.
    const responderResource = await lockResponderResource(tx, responderResourceId);
    if (!responderResource) throw new Error('Responder resource not found');
    if (responderResource.responderId !== Number(responderId)) {
      throw new Error('Responder mismatch: unauthorized');
    }
    if (responderResource.resourceId !== resourceId) {
      throw new Error('Resource mismatch');
    }

    // Lock the required line too; it makes the request-resource requirement
    // part of the same protected state transition.
    const lockedRequired = await tx.$queryRaw`
      SELECT id, quantity
      FROM "RequestResource"
      WHERE "requestId" = ${requestId} AND "resourceId" = ${resourceId}
      FOR UPDATE
    `;
    const required = lockedRequired[0];
    if (!required) throw new Error('Resource is not required by this request');

    const catalogResource = await tx.resource.findUnique({
      where: { id: resourceId },
      select: { id: true, isActive: true, mode: true },
    });
    if (!catalogResource || !catalogResource.isActive) {
      throw new Error('Resource is not active');
    }

    const existingAllocations = await tx.allocation.findMany({
      where: {
        requestId,
        resourceId,
        status: { not: 'CANCELLED' },
      },
      select: { quantity: true },
    });
    const alreadyAllocated = existingAllocations.reduce(
      (sum, allocation) => sum + allocation.quantity,
      0
    );
    const outstanding = required.quantity - alreadyAllocated;

    if (outstanding <= 0) {
      throw new Error('This resource is already fully allocated');
    }
    if (quantity > outstanding) {
      throw new Error(
        `Allocation exceeds the remaining required quantity (${outstanding} left)`
      );
    }

    if (catalogResource.mode === 'CONSUMABLE') {
      if (responderResource.availableQuantity < quantity) {
        throw new Error('Not enough available quantity');
      }

      const remainingAvailableQuantity =
        responderResource.availableQuantity - quantity;
      await tx.responderResource.update({
        where: { id: responderResourceId },
        data: {
          availableQuantity: remainingAvailableQuantity,
          // Availability status follows actual stock. It is deliberately not a
          // durable willingness flag; isEnabled remains unchanged.
          ...(remainingAvailableQuantity === 0 ? { status: 'UNAVAILABLE' } : {}),
        },
      });
    }
    // SERVICE resources are reusable responder capabilities: no quantity
    // check and no inventory decrement. The responder can provide the same
    // SERVICE resource unlimited sequential times; their only limitation is
    // current availability (enforced by responderStatus/BUSY tracking), not
    // a lifetime-use counter.

    const allocation = await tx.allocation.create({
      data: {
        requestId,
        responderResourceId,
        responderId: Number(responderId),
        resourceId,
        quantity,
        status: 'RESERVED',
      },
    });

    await syncRequestStatus(tx, requestId);
    await syncResponderAvailability(tx, responderId);

    return allocation;
  });
};

exports.updateAllocationStatus = async (responderId, allocationId, status) => {
  const numericAllocationId = asPositiveInteger(allocationId, 'allocationId');

  if (!['DISPATCHED', 'CANCELLED'].includes(status)) {
    throw new Error('Responders may only dispatch or cancel an allocation');
  }

  return runSerializableTransaction(async (tx) => {
    const allocation = await lockAllocation(tx, numericAllocationId);
    if (!allocation) throw new Error('Allocation not found');
    if (allocation.responderId !== Number(responderId)) {
      throw new Error('Unauthorized');
    }
    if (allocation.status === 'CANCELLED') throw new Error('Already cancelled');
    if (allocation.status === 'DELIVERED') throw new Error('Already delivered');

    if (status === 'DISPATCHED' && allocation.status !== 'RESERVED') {
      throw new Error('Only RESERVED allocations can be dispatched');
    }

    if (status === 'CANCELLED') {
      const resourceRow = await tx.resource.findUnique({
        where: { id: allocation.resourceId },
        select: { mode: true },
      });

      // SERVICE allocations never decremented inventory, so cancelling one
      // must never "restore" inventory either - that would fabricate stock.
      if (!resourceRow || resourceRow.mode === 'CONSUMABLE') {
        const responderResource = await lockResponderResource(
          tx,
          allocation.responderResourceId
        );
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
    }

    const updated = await tx.allocation.update({
      where: { id: numericAllocationId },
      data: { status },
    });

    await syncRequestStatus(tx, allocation.requestId);
    await syncResponderAvailability(tx, allocation.responderId);
    return updated;
  });
};

exports.confirmAllocationReceived = async (requesterId, allocationId) => {
  const numericAllocationId = asPositiveInteger(allocationId, 'allocationId');

  return runSerializableTransaction(async (tx) => {
    const allocation = await lockAllocation(tx, numericAllocationId);
    if (!allocation) throw new Error('Allocation not found');

    const lockedRequests = await tx.$queryRaw`
      SELECT id, "requesterId", status
      FROM "EmergencyRequest"
      WHERE id = ${allocation.requestId}
      FOR UPDATE
    `;
    const request = lockedRequests[0];
    if (!request) throw new Error('Emergency request not found');
    if (request.requesterId !== Number(requesterId)) {
      throw new Error('Unauthorized');
    }
    if (allocation.status === 'CANCELLED') {
      throw new Error('Cancelled allocations cannot be received');
    }
    if (allocation.status === 'DELIVERED') {
      throw new Error('Receipt has already been confirmed');
    }
    if (allocation.status !== 'DISPATCHED') {
      throw new Error('Only DISPATCHED allocations can be confirmed as received');
    }

    const updated = await tx.allocation.update({
      where: { id: numericAllocationId },
      data: { status: 'DELIVERED' },
    });

    await syncRequestStatus(tx, allocation.requestId);
    await syncResponderAvailability(tx, allocation.responderId);
    return updated;
  });
};

// Exported for focused service tests and for other lifecycle callers.
exports.syncRequestStatus = syncRequestStatus;
