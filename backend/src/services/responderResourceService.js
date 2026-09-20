const prisma = require('../config/prisma');

const validateQuantities = (total, available) => {
  if (total !== undefined && total < 0) throw new Error('Total quantity must be >= 0');
  if (available !== undefined && available < 0) throw new Error('Available quantity must be >= 0');
  if (total !== undefined && available !== undefined && available > total) {
    throw new Error('Available quantity cannot exceed total quantity');
  }
};

exports.getResourcesByResponder = async (responderId) => {
  return await prisma.responderResource.findMany({ where: { responderId } });
};

exports.addResource = async (responderId, data) => {
  const total = data.totalQuantity || 0;
  const avail = data.availableQuantity || 0;
  validateQuantities(total, avail);

  return await prisma.responderResource.create({
    data: {
      ...data,
      responderId
    }
  });
};

exports.updateResource = async (responderId, id, data) => {
  const resource = await prisma.responderResource.findUnique({ where: { id: Number(id) } });
  if (!resource) throw new Error('Resource not found');
  if (resource.responderId !== responderId) throw new Error('You can only manage your own resources');

  const newTotal = data.totalQuantity !== undefined ? data.totalQuantity : resource.totalQuantity;
  const newAvail = data.availableQuantity !== undefined ? data.availableQuantity : resource.availableQuantity;
  validateQuantities(newTotal, newAvail);

  return await prisma.responderResource.update({
    where: { id: Number(id) },
    data
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