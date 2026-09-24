const prisma = require('../config/prisma');

const VALID_RESOURCE_STATUSES = ['AVAILABLE', 'BUSY', 'UNAVAILABLE'];

// Shared shape so responder inventory always carries the readable
// responder + resource information (name, type, unit, location).
const responderResourceInclude = {
  responder: {
    select: {
      id: true,
      name: true,
      email: true,
      phone: true,
      responderStatus: true,
    },
  },
  resource: {
    select: {
      id: true,
      name: true,
      type: true,
      unit: true,
      location: true,
      isActive: true,
    },
  },
};

const validateStatus = (status) => {
  if (status === undefined) return;
  if (!VALID_RESOURCE_STATUSES.includes(status)) {
    throw new Error(
      `Invalid status. Valid statuses: ${VALID_RESOURCE_STATUSES.join(', ')}`
    );
  }
};

const validateQuantities = (total, available) => {
  if (total !== undefined && total < 0) throw new Error('Total quantity must be >= 0');
  if (available !== undefined && available < 0) throw new Error('Available quantity must be >= 0');
  if (total !== undefined && available !== undefined && available > total) {
    throw new Error('Available quantity cannot exceed total quantity');
  }
};

exports.getResourcesByResponder = async (responderId) => {
  return await prisma.responderResource.findMany({
    where: { responderId: Number(responderId) },
    include: responderResourceInclude,
    orderBy: { id: 'asc' },
  });
};

exports.addResource = async (responderId, data) => {
  const total = data.totalQuantity || 0;
  const avail = data.availableQuantity || 0;
  validateQuantities(total, avail);
  validateStatus(data.status);

  const resourceId = Number(data.resourceId);

  if (!Number.isInteger(resourceId) || resourceId <= 0) {
    throw new Error('A valid resourceId is required');
  }

  const resource = await prisma.resource.findUnique({
    where: { id: resourceId },
  });

  if (!resource) throw new Error('Resource not found');

  return await prisma.responderResource.create({
    data: {
      ...data,
      resourceId,
      responderId
    },
    include: responderResourceInclude,
  });
};

exports.updateResource = async (responderId, id, data) => {
  const resource = await prisma.responderResource.findUnique({ where: { id: Number(id) } });
  if (!resource) throw new Error('Resource not found');
  if (resource.responderId !== responderId) throw new Error('You can only manage your own resources');

  const newTotal = data.totalQuantity !== undefined ? data.totalQuantity : resource.totalQuantity;
  const newAvail = data.availableQuantity !== undefined ? data.availableQuantity : resource.availableQuantity;
  validateQuantities(newTotal, newAvail);
  validateStatus(data.status);

  return await prisma.responderResource.update({
    where: { id: Number(id) },
    data,
    include: responderResourceInclude,
  });
};

exports.deleteResource = async (responderId, id) => {
  const resource = await prisma.responderResource.findUnique({ where: { id: Number(id) } });
  if (!resource) throw new Error('Resource not found');
  if (resource.responderId !== responderId) throw new Error('You can only manage your own resources');

  return await prisma.responderResource.delete({
    where: { id: Number(id) }
  });
};
exports.getAllResources = async () => {
  return await prisma.responderResource.findMany({
    include: responderResourceInclude,
    orderBy: {
      id: "asc",
    },
  });
};