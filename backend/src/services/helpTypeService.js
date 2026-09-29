const prisma = require('../config/prisma');
const { runSerializableTransaction } = require('./transactionService');
const { syncResponderAvailability } = require('./lifecycleService');
const { emitResponderAvailability } = require('../realtime/eventEmitters');
const {
  HELP_TYPES,
  HELP_TYPE_VALUES,
  categoryForEmergencyType,
  normalizeHelpType,
} = require('../domain/emergencyCategories');

async function assertResponder(client, responderId) {
  const responder = await client.user.findUnique({
    where: { id: Number(responderId) },
    select: { id: true, role: true },
  });
  if (!responder || responder.role !== 'RESPONDER') {
    throw new Error('Only responders can manage help types');
  }
  return responder;
}

async function getHelpTypes(responderId) {
  const responder = await assertResponder(prisma, responderId);
  const rows = await prisma.responderHelpType.findMany({
    where: { responderId: responder.id, enabled: true },
    select: { category: true },
    orderBy: { category: 'asc' },
  });
  return {
    categories: HELP_TYPES,
    selected: rows.map((row) => row.category),
  };
}

async function updateHelpTypes(responderId, values) {
  if (!Array.isArray(values)) throw new Error('helpTypes must be an array');

  const normalized = values.map(normalizeHelpType);
  if (normalized.some((value) => value === null)) {
    throw new Error('One or more help types are invalid');
  }
  const selected = new Set(normalized);

  const result = await runSerializableTransaction(async (tx) => {
    const numericResponderId = Number(responderId);
    // Serialize readiness changes with request acceptance, which locks the same
    // User row before re-checking category eligibility.
    const lockedResponders = await tx.$queryRaw`
      SELECT id, role
      FROM "User"
      WHERE id = ${numericResponderId}
      FOR UPDATE
    `;
    const responder = lockedResponders[0];
    if (!responder || responder.role !== 'RESPONDER') {
      throw new Error('Only responders can manage help types');
    }

    for (const category of HELP_TYPE_VALUES) {
      await tx.responderHelpType.upsert({
        where: {
          responderId_category: { responderId: responder.id, category },
        },
        update: { enabled: selected.has(category) },
        create: {
          responderId: responder.id,
          category,
          enabled: selected.has(category),
        },
      });
    }
    await syncResponderAvailability(tx, responder.id);
    return {
      categories: HELP_TYPES,
      selected: HELP_TYPES.map((item) => item.value).filter((value) => selected.has(value)),
    };
  });

  try {
    await emitResponderAvailability(Number(responderId));
  } catch (error) {
    console.error('Realtime emission failed:', error.message);
  }
  return result;
}

module.exports = {
  HELP_TYPES,
  categoryForEmergencyType,
  getHelpTypes,
  normalizeHelpType,
  updateHelpTypes,
};
