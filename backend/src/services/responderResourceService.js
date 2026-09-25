const prisma = require('../config/prisma');
const { runSerializableTransaction } = require('./transactionService');
const { syncResponderAvailability } = require('./lifecycleService');

const VALID_RESOURCE_STATUSES = ['AVAILABLE', 'BUSY', 'UNAVAILABLE'];

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
      mode: true,
      unit: true,
      location: true,
      isActive: true,
    },
  },
};

function toInteger(value, field) {
  const number = Number(value);
  if (!Number.isInteger(number)) throw new Error(`${field} must be an integer`);
  return number;
}

function validateStatus(status) {
  if (status === undefined) return;
  if (!VALID_RESOURCE_STATUSES.includes(status)) {
    throw new Error(
      `Invalid status. Valid statuses: ${VALID_RESOURCE_STATUSES.join(', ')}`
    );
  }
}

function validateBoolean(value, field) {
  if (value !== undefined && typeof value !== 'boolean') {
    throw new Error(`${field} must be a boolean`);
  }
}

function validateQuantities(total, available) {
  if (!Number.isInteger(total) || total < 0) {
    throw new Error('Total quantity must be a non-negative integer');
  }
  if (!Number.isInteger(available) || available < 0) {
    throw new Error('Available quantity must be a non-negative integer');
  }
  if (available > total) {
    throw new Error('Available quantity cannot exceed total quantity');
  }
}

function normaliseActor(actor) {
  if (typeof actor === 'number') return { id: actor, role: 'RESPONDER' };
  return actor;
}

function mutationData(data, existing, responder, resourceMode) {
  validateStatus(data.status);
  validateBoolean(data.isEnabled, 'isEnabled');

  const totalQuantity =
    data.totalQuantity === undefined
      ? existing.totalQuantity
      : toInteger(data.totalQuantity, 'Total quantity');
  const availableQuantity =
    data.availableQuantity === undefined
      ? existing.availableQuantity
      : toInteger(data.availableQuantity, 'Available quantity');
  validateQuantities(totalQuantity, availableQuantity);

  const isEnabled =
    data.isEnabled === undefined ? existing.isEnabled : data.isEnabled;

  let status = data.status === undefined ? existing.status : data.status;

  if (resourceMode === 'SERVICE') {
    // SERVICE resources are reusable responder capabilities: selection means
    // capability only. Quantity is not a signal of availability, so it never
    // drives this status column for SERVICE rows.
    if (data.status === undefined) {
      status = isEnabled ? 'AVAILABLE' : 'UNAVAILABLE';
    }
  } else {
    // CONSUMABLE: selection means capability + inventory. Zero inventory is
    // never currently available, even if a stale client submits AVAILABLE.
    // An explicit UNAVAILABLE/BUSY choice is otherwise kept.
    if (availableQuantity === 0) {
      status = 'UNAVAILABLE';
    } else if (
      data.status === undefined &&
      isEnabled &&
      availableQuantity > 0 &&
      (data.isEnabled === true ||
        (data.availableQuantity !== undefined && existing.status === 'UNAVAILABLE'))
    ) {
      // Readiness SAVE and a restock from zero should make stock usable
      // without relying on the responder's previous overall status.
      status = 'AVAILABLE';
    }
  }

  return { totalQuantity, availableQuantity, isEnabled, status, responder };
}

exports.getResourcesByResponder = async (responderId) =>
  prisma.responderResource.findMany({
    where: { responderId: Number(responderId) },
    include: responderResourceInclude,
    orderBy: { id: 'asc' },
  });

exports.addResource = async (actorInput, data) => {
  const actor = normaliseActor(actorInput);
  const resourceId = toInteger(data.resourceId, 'resourceId');
  if (resourceId <= 0) throw new Error('A valid resourceId is required');

  const targetResponderId =
    actor.role === 'ADMIN' && data.responderId !== undefined
      ? toInteger(data.responderId, 'responderId')
      : Number(actor.id);

  if (actor.role !== 'ADMIN' && targetResponderId !== Number(actor.id)) {
    throw new Error('You can only manage your own resources');
  }

  const totalQuantity =
    data.totalQuantity === undefined ? 0 : toInteger(data.totalQuantity, 'Total quantity');
  const availableQuantity =
    data.availableQuantity === undefined
      ? 0
      : toInteger(data.availableQuantity, 'Available quantity');
  const isEnabled = data.isEnabled === undefined ? false : data.isEnabled;
  validateBoolean(isEnabled, 'isEnabled');
  validateStatus(data.status);
  validateQuantities(totalQuantity, availableQuantity);

  return runSerializableTransaction(async (tx) => {
    const [catalogResource, responder] = await Promise.all([
      tx.resource.findUnique({ where: { id: resourceId } }),
      tx.user.findUnique({ where: { id: targetResponderId } }),
    ]);
    if (!catalogResource) throw new Error('Resource not found');
    if (!responder || responder.role !== 'RESPONDER') {
      throw new Error('Responder not found');
    }

    let status = data.status || 'UNAVAILABLE';
    if (catalogResource.mode === 'SERVICE') {
      // Reusable responder capability: selection alone determines status.
      if (data.status === undefined) status = isEnabled ? 'AVAILABLE' : 'UNAVAILABLE';
    } else {
      if (availableQuantity === 0) status = 'UNAVAILABLE';
      else if (data.status === undefined && isEnabled) status = 'AVAILABLE';
    }

    const created = await tx.responderResource.create({
      data: {
        responderId: targetResponderId,
        resourceId,
        totalQuantity,
        availableQuantity,
        isEnabled,
        status,
      },
      include: responderResourceInclude,
    });

    await syncResponderAvailability(tx, targetResponderId);
    return created;
  });
};

exports.updateResource = async (actorInput, id, data) => {
  const actor = normaliseActor(actorInput);
  const resourceRowId = toInteger(id, 'resource id');

  return runSerializableTransaction(async (tx) => {
    const locked = await tx.$queryRaw`
      SELECT id, "responderId", "resourceId", "totalQuantity", "availableQuantity",
             "isEnabled", status
      FROM "ResponderResource"
      WHERE id = ${resourceRowId}
      FOR UPDATE
    `;
    const existing = locked[0];
    if (!existing) throw new Error('Resource not found');
    if (actor.role !== 'ADMIN' && existing.responderId !== Number(actor.id)) {
      throw new Error('You can only manage your own resources');
    }

    const [responder, catalogResource] = await Promise.all([
      tx.user.findUnique({
        where: { id: existing.responderId },
        select: { id: true, role: true },
      }),
      tx.resource.findUnique({
        where: { id: existing.resourceId },
        select: { mode: true },
      }),
    ]);
    if (!responder || responder.role !== 'RESPONDER') {
      throw new Error('Responder not found');
    }

    const next = mutationData(data, existing, responder, catalogResource?.mode);
    const updated = await tx.responderResource.update({
      where: { id: resourceRowId },
      data: {
        totalQuantity: next.totalQuantity,
        availableQuantity: next.availableQuantity,
        isEnabled: next.isEnabled,
        status: next.status,
      },
      include: responderResourceInclude,
    });

    await syncResponderAvailability(tx, existing.responderId);
    return updated;
  });
};

exports.deleteResource = async (actorInput, id) => {
  const actor = normaliseActor(actorInput);
  const resourceRowId = toInteger(id, 'resource id');

  return runSerializableTransaction(async (tx) => {
    const existing = await tx.responderResource.findUnique({
      where: { id: resourceRowId },
    });
    if (!existing) throw new Error('Resource not found');
    if (actor.role !== 'ADMIN' && existing.responderId !== Number(actor.id)) {
      throw new Error('You can only manage your own resources');
    }

    const deleted = await tx.responderResource.delete({
      where: { id: resourceRowId },
    });
    await syncResponderAvailability(tx, existing.responderId);
    return deleted;
  });
};

exports.getAllResources = async () =>
  prisma.responderResource.findMany({
    include: responderResourceInclude,
    orderBy: { id: 'asc' },
  });
