const prisma = require('../config/prisma');

exports.getAllocationsByResponder = async (responderId) => {
  return await prisma.allocation.findMany({
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
        },
      },
    },
    orderBy: { allocatedAt: 'desc' },
  });
};

/**
 * PostgreSQL aborts the losing side of a Serializable conflict with
 * SQLSTATE 40001 / 40P01 (Prisma surfaces it as P2034). The safe and standard
 * answer is to retry the whole transaction: the concurrency guarantees are
 * unchanged (Serializable + SELECT ... FOR UPDATE), but the caller gets the
 * real business error ("Not enough available quantity") instead of a
 * database-level serialization message.
 */
function isRetryableTransactionError(error) {
  if (!error) return false;
  if (error.code === 'P2034') return true;

  return /40001|40P01|could not serialize|deadlock detected/i.test(
    error.message || ''
  );
}

async function runSerializableTransaction(callback, retries = 5) {
  let lastError;

  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      return await prisma.$transaction(callback, {
        isolationLevel: 'Serializable',
      });
    } catch (error) {
      if (!isRetryableTransactionError(error)) {
        throw error;
      }

      lastError = error;

      // Small staggered back-off before retrying.
      await new Promise((resolve) =>
        setTimeout(resolve, 10 * (attempt + 1) + Math.floor(Math.random() * 10))
      );
    }
  }

  throw lastError;
}

async function syncRequestStatus(tx, requestId) {
  const request = await tx.emergencyRequest.findUnique({
    where: { id: requestId },
    include: { requiredResources: true, allocations: true }
  });

  if (!request) return;

  const requiredAmounts = {};
  for (const rr of request.requiredResources) {
    requiredAmounts[rr.resourceId] = rr.quantity;
  }

  const allocatedAmounts = {};
  for (const alloc of request.allocations) {
    if (alloc.status !== 'CANCELLED') {
      allocatedAmounts[alloc.resourceId] = (allocatedAmounts[alloc.resourceId] || 0) + alloc.quantity;
    }
  }

  let allFulfilled = request.requiredResources.length > 0;
  let partial = false;

  for (const resId in requiredAmounts) {
    const required = requiredAmounts[resId];
    const allocated = allocatedAmounts[resId] || 0;

    if (allocated > 0) {
      partial = true;
    }

   if (allocated < required) {
     allFulfilled = false;
    }
}
  let newStatus = request.status;

  if (allFulfilled) {
    newStatus = 'COMPLETED';
  } else if (partial) {
    newStatus = 'PARTIALLY_ALLOCATED';
  } else if (
    request.status === 'COMPLETED' ||
    request.status === 'PARTIALLY_ALLOCATED'
  ) {
    // All allocations were cancelled.
    // Reopen the request so a responder can allocate again.
    newStatus = 'ACCEPTED';
  }

  if (newStatus !== request.status) {
    await tx.emergencyRequest.update({
      where: { id: requestId },
      data: { status: newStatus }
    });
  }
}

exports.createAllocation = async (responderId, data) => {
  const { requestId, responderResourceId, resourceId, quantity } = data;
  if (!quantity || quantity <= 0) throw new Error('Quantity must be greater than 0');

  return await runSerializableTransaction(async (tx) => {
    const reqInstance = await tx.emergencyRequest.findUnique({ where: { id: Number(requestId) } });
    if (!reqInstance || reqInstance.status === 'CANCELLED' || reqInstance.status === 'COMPLETED') {
      throw new Error('Request is invalid or already closed');
    }

    // SELECT FOR UPDATE acquires a row-level lock so concurrent transactions
    // must wait — preventing double-spend of availableQuantity.
    const locked = await tx.$queryRaw`
      SELECT id, "responderId", "resourceId", "availableQuantity"
      FROM "ResponderResource"
      WHERE id = ${Number(responderResourceId)}
      FOR UPDATE
    `;

    const respResource = locked[0];
    if (!respResource) throw new Error('Responder resource not found');
    if (respResource.responderId !== responderId) throw new Error('Responder mismatch: unauthorized');
    if (respResource.resourceId !== resourceId) throw new Error('Resource mismatch');

    // The resource must actually be required by this emergency, and each
    // required resource is allocated independently of the others.
    const required = await tx.requestResource.findFirst({
      where: {
        requestId: Number(requestId),
        resourceId: Number(resourceId),
      },
    });

    if (!required) {
      throw new Error('Resource is not required by this request');
    }

    const existingAllocations = await tx.allocation.findMany({
      where: {
        requestId: Number(requestId),
        resourceId: Number(resourceId),
        status: {
          not: 'CANCELLED',
        },
      },
      select: {
        quantity: true,
      },
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

    if (respResource.availableQuantity < quantity) {
      throw new Error('Not enough available quantity');
    }

    await tx.responderResource.update({
      where: { id: Number(responderResourceId) },
      data: { availableQuantity: respResource.availableQuantity - quantity }
    });

    const allocation = await tx.allocation.create({
      data: {
        requestId: Number(requestId),
        responderResourceId: Number(responderResourceId),
        responderId,
        resourceId: Number(resourceId),
        quantity,
        status: 'RESERVED'
      }
    });

    await syncRequestStatus(tx, Number(requestId));

    return allocation;
  });
};


exports.updateAllocationStatus = async (responderId, allocationId, status) => {
  return await prisma.$transaction(async (tx) => {
    const allocation = await tx.allocation.findUnique({ where: { id: Number(allocationId) } });
    if (!allocation) throw new Error('Allocation not found');
    if (allocation.responderId !== responderId) throw new Error('Unauthorized');

    if (allocation.status === 'CANCELLED') throw new Error('Already cancelled');

    if (status === 'CANCELLED') {
      // Return inventory
      const respResource = await tx.responderResource.findUnique({ where: { id: allocation.responderResourceId } });
      if (respResource) {
        await tx.responderResource.update({
          where: { id: allocation.responderResourceId },
          data: { availableQuantity: respResource.availableQuantity + allocation.quantity }
        });
      }
    }

    const updated = await tx.allocation.update({
      where: { id: Number(allocationId) },
      data: { status }
    });

    await syncRequestStatus(tx, allocation.requestId);
    return updated;
  });
};