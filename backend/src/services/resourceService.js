const prisma = require('../config/prisma');

exports.createResource = async (data) => {
  return await prisma.resource.create({ data });
};

exports.getAllResources = async () => {
  return await prisma.resource.findMany();
};

exports.getResourceById = async (id) => {
  return await prisma.resource.findUniqueOrThrow({ where: { id: Number(id) } });
};

exports.updateResource = async (id, data) => {
  return await prisma.resource.update({ where: { id: Number(id) }, data });
};

exports.deleteResource = async (id) => {
  return await prisma.resource.delete({ where: { id: Number(id) } });
};