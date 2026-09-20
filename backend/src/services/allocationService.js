const prisma = require('../config/prisma');

exports.getAllocationsByResponder = async (responderId) => {
  return await prisma.allocation.findMany({ where: { responderId } });
};

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

  let allFulfilled = true;
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

  return await prisma.(async (tx) => {
    const reqInstance = await tx.emergencyRequest.findUnique({ where: { id: Number(requestId) }});
    if (!reqInstance || reqInstance.status === 'CANCELLED' || reqInstance.status === 'COMPLETED') {
      throw new Error('Request is invalid or already closed');
    }

    const respResource = await tx.responderResource.findUnique({ where: { id: Number(responderResourceId) } });
    if (!respResource) throw new Error('Responder resource not found');
    if (respResource.responderId !== responderId) throw new Error('Responder mismatch: unauthorized');
    if (respResource.resourceId !== resourceId) throw new Error('Resource mismatch');
    
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
  return await prisma.(async (tx) => {
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