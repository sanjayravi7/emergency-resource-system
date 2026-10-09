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
 * Spendable consumable stock lives only in ResponderResource. Sum each eligible
 * inventory row once; catalog quantities are administrative metadata, not a
 * second pool of stock. BUSY responders retain unspent stock for allocations
 * on their current work, while OFFLINE responders cannot be dispatched.
 */
const consumableInventoryWhere = {
  isEnabled: true,
  status: 'AVAILABLE',
  availableQuantity: { gt: 0 },
  responder: {
    role: 'RESPONDER',
    isActive: true,
    responderStatus: { in: ['AVAILABLE', 'BUSY'] },
  },
  resource: { isActive: true, mode: 'CONSUMABLE' },
};

async function getConsumableStock(resourceIds) {
  if (!resourceIds.length) return new Map();
  const rows = await prisma.responderResource.groupBy({
    by: ['resourceId'],
    where: {
      ...consumableInventoryWhere,
      resourceId: { in: resourceIds },
    },
    _sum: { totalQuantity: true, availableQuantity: true },
  });
  return new Map(rows.map((row) => [row.resourceId, {
    totalQuantity: row._sum.totalQuantity ?? 0,
    availableQuantity: row._sum.availableQuantity ?? 0,
  }]));
}

exports.getConsumableStock = getConsumableStock;

/** Operational availability for every active catalog resource. */
exports.getResourceAvailability = async () => {
  const resources = await prisma.resource.findMany({
    where: { isActive: true },
    orderBy: [{ name: 'asc' }],
  });
  const stock = await getConsumableStock(
    resources.filter((resource) => resource.mode === 'CONSUMABLE').map((resource) => resource.id)
  );

  return Promise.all(
    resources.map(async (resource) => {
      if (resource.mode === 'SERVICE') {
        const availableResponders = await prisma.responderResource.count({
          where: {
            resourceId: resource.id,
            isEnabled: true,
            responder: {
              role: 'RESPONDER',
              isActive: true,
              responderStatus: 'AVAILABLE',
            },
          },
        });

        return {
          id: resource.id,
          name: resource.name,
          type: resource.type,
          mode: resource.mode,
          unit: resource.unit,
          availableResponders,
          totalQuantity: null,
          availableQuantity: null,
        };
      }

      return {
        id: resource.id,
        name: resource.name,
        type: resource.type,
        mode: resource.mode,
        unit: resource.unit,
        availableResponders: null,
        totalQuantity: stock.get(resource.id)?.totalQuantity ?? 0,
        availableQuantity: stock.get(resource.id)?.availableQuantity ?? 0,
      };
    })
  );
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
