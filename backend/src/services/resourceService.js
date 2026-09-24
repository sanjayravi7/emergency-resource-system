const prisma = require('../config/prisma');

const {
  validateResourceInput,
  normalizeResourceInput,
} = require('../validators/resourceValidator');

// ----------------------------------------------------------
// CREATE
// ----------------------------------------------------------
exports.createResource = async (data) => {
  const validationError = validateResourceInput(data, { partial: false });
  if (validationError) throw new Error(validationError);

  return await prisma.resource.create({
    data: normalizeResourceInput(data, { partial: false }),
  });
};

// ----------------------------------------------------------
// READ
//
// PostgreSQL is the source of truth for the resource catalog.
// `activeOnly` is used for requesters/responders so inactive
// resources are never offered for selection.
// ----------------------------------------------------------
exports.getAllResources = async (options = {}) => {
  const { activeOnly = false, type, search } = options;

  const where = {};

  if (activeOnly) {
    where.isActive = true;
  }

  if (type) {
    where.type = String(type);
  }

  if (search) {
    where.name = {
      contains: String(search),
      mode: 'insensitive',
    };
  }

  return await prisma.resource.findMany({
    where,
    orderBy: [{ name: 'asc' }],
  });
};

exports.getResourceById = async (id) => {
  return await prisma.resource.findUniqueOrThrow({ where: { id: Number(id) } });
};

/**
 * Low-stock visibility: availableQuantity <= lowStockThreshold.
 * Uses a raw query because the comparison is column-to-column.
 */
exports.getLowStockResources = async () => {
  return await prisma.$queryRaw`
    SELECT *
    FROM "Resource"
    WHERE "isActive" = true
      AND "availableQuantity" <= "lowStockThreshold"
    ORDER BY "availableQuantity" ASC, "name" ASC
  `;
};

// ----------------------------------------------------------
// UPDATE
// ----------------------------------------------------------
exports.updateResource = async (id, data) => {
  const existing = await prisma.resource.findUnique({
    where: { id: Number(id) },
  });

  if (!existing) throw new Error('Resource not found');

  const validationError = validateResourceInput(data, { partial: true }, existing);
  if (validationError) throw new Error(validationError);

  return await prisma.resource.update({
    where: { id: Number(id) },
    data: normalizeResourceInput(data, { partial: true }),
  });
};

/**
 * Deactivate / restore a resource without deleting history.
 * Inactive resources stay in PostgreSQL but are hidden from requesters.
 */
exports.setResourceActive = async (id, isActive) => {
  const existing = await prisma.resource.findUnique({
    where: { id: Number(id) },
  });

  if (!existing) throw new Error('Resource not found');

  return await prisma.resource.update({
    where: { id: Number(id) },
    data: { isActive: Boolean(isActive) },
  });
};

// ----------------------------------------------------------
// DELETE (hard delete, ADMIN only)
// ----------------------------------------------------------
exports.deleteResource = async (id) => {
  return await prisma.resource.delete({ where: { id: Number(id) } });
};
