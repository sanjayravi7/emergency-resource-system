/**
 * Development-only diagnostic.
 *
 * Answers the question: "Why does / doesn't a PENDING request show up on the
 * responder's dispatch board?"  It prints the responder, their inventory, every
 * PENDING request with its required resources, and a per-request COMPATIBLE /
 * NOT COMPATIBLE verdict computed with the SAME rules the API uses
 * (integer resourceId + available quantity, never resource names).
 *
 * This script is READ-ONLY. It never modifies any data.
 *
 * Usage:
 *   node scripts/check-responder-compatibility.js               # dev responder
 *   node scripts/check-responder-compatibility.js <responderId> # a specific id
 *   node scripts/check-responder-compatibility.js <email>       # a specific email
 */

const prisma = require('../src/config/prisma');

const ACTIVE_STATUSES = ['ACCEPTED', 'IN_PROGRESS', 'PARTIALLY_ALLOCATED'];

async function findResponder(argument) {
  if (argument) {
    // Numeric argument -> id, otherwise treat as email.
    if (/^\d+$/.test(argument)) {
      return prisma.user.findUnique({ where: { id: Number(argument) } });
    }
    return prisma.user.findUnique({ where: { email: argument } });
  }

  // Default: the seeded development responder, else the first RESPONDER.
  const dev = await prisma.user.findUnique({
    where: { email: 'responder49@eras.dev' },
  });
  if (dev) return dev;

  return prisma.user.findFirst({ where: { role: 'RESPONDER' } });
}

async function main() {
  const argument = process.argv[2];
  const responder = await findResponder(argument);

  if (!responder) {
    console.log('No responder found. Run `npm run seed` first.');
    return;
  }

  // ----------------------------------------------------------------
  // 1 + 2. Responder identity / status
  // ----------------------------------------------------------------
  console.log('==================================================');
  console.log('RESPONDER');
  console.log('==================================================');
  console.log(`  id:              ${responder.id}`);
  console.log(`  name:            ${responder.name}`);
  console.log(`  email:           ${responder.email}`);
  console.log(`  role:            ${responder.role}`);
  console.log(`  isActive:        ${responder.isActive}`);
  console.log(`  responderStatus: ${responder.responderStatus}`);

  const activeEmergency = await prisma.emergencyRequest.findFirst({
    where: {
      acceptedById: responder.id,
      status: { in: ACTIVE_STATUSES },
    },
    select: { id: true, status: true },
  });

  console.log(
    `  activeEmergency: ${
      activeEmergency
        ? `#${activeEmergency.id} (${activeEmergency.status})`
        : 'none'
    }`
  );

  // ----------------------------------------------------------------
  // 3. Responder inventory
  // ----------------------------------------------------------------
  const inventory = await prisma.responderResource.findMany({
    where: { responderId: responder.id },
    include: { resource: true },
    orderBy: { resourceId: 'asc' },
  });

  console.log('\n==================================================');
  console.log('RESPONDER INVENTORY (ResponderResource rows)');
  console.log('==================================================');
  if (!inventory.length) {
    console.log('  (no inventory rows — this responder can match NOTHING)');
  }
  for (const row of inventory) {
    console.log(
      `  resourceId=${row.resourceId} ` +
        `name="${row.resource.name}" type=${row.resource.type} ` +
        `available=${row.availableQuantity}/${row.totalQuantity} ` +
        `status=${row.status}`
    );
  }

  // A quick-lookup map keyed by the integer resourceId (never by name).
  const inventoryById = new Map(inventory.map((r) => [r.resourceId, r]));

  // ----------------------------------------------------------------
  // 4 + 5. Pending requests and their required resources
  // ----------------------------------------------------------------
  const pending = await prisma.emergencyRequest.findMany({
    where: { status: 'PENDING' },
    include: {
      requiredResources: { include: { resource: true } },
      requester: { select: { name: true, email: true } },
    },
    orderBy: [{ priority: 'desc' }, { createdAt: 'asc' }],
  });

  console.log('\n==================================================');
  console.log(`PENDING REQUESTS (${pending.length})`);
  console.log('==================================================');

  // Responder-level gates that hide EVERY pending request.
  const responderBlocked =
    responder.role !== 'RESPONDER' ||
    !responder.isActive ||
    responder.responderStatus !== 'AVAILABLE' ||
    !!activeEmergency;

  if (responderBlocked) {
    const reasons = [];
    if (responder.role !== 'RESPONDER') reasons.push('role is not RESPONDER');
    if (!responder.isActive) reasons.push('isActive is false');
    if (responder.responderStatus !== 'AVAILABLE') {
      reasons.push(`responderStatus is ${responder.responderStatus} (need AVAILABLE)`);
    }
    if (activeEmergency) {
      reasons.push(`already handling active emergency #${activeEmergency.id}`);
    }
    console.log(
      `\n!! Responder-level block: ${reasons.join('; ')}.` +
        '\n!! While this is true NO pending request will be offered.\n'
    );
  }

  for (const request of pending) {
    console.log(`\n--- Request #${request.id} -----------------------------`);
    console.log(
      `  ${request.emergencyType} @ ${request.location} ` +
        `[${request.priority}] by ${request.requester.name} <${request.requester.email}>`
    );
    console.log('  Required resources:');
    if (!request.requiredResources.length) {
      console.log('    (none — a request with no requirements is never matched)');
    }
    for (const req of request.requiredResources) {
      console.log(
        `    resourceId=${req.resourceId} ` +
          `name="${req.resource.name}" quantity=${req.quantity}`
      );
    }

    // ------------------------------------------------------------
    // 6 + 7. Compatibility verdict (same rules as the API)
    // ------------------------------------------------------------
    let compatible = request.requiredResources.length > 0;
    const reasons = [];

    for (const req of request.requiredResources) {
      const owned = inventoryById.get(req.resourceId);
      if (!owned) {
        compatible = false;
        reasons.push(`resourceId ${req.resourceId} missing from inventory`);
      } else if (owned.status !== 'AVAILABLE') {
        compatible = false;
        reasons.push(
          `resourceId ${req.resourceId} status is ${owned.status} (need AVAILABLE)`
        );
      } else if (owned.availableQuantity < req.quantity) {
        compatible = false;
        reasons.push(
          `resourceId ${req.resourceId} available ${owned.availableQuantity} < required ${req.quantity}`
        );
      }
    }

    if (!request.requiredResources.length) {
      reasons.push('request has no required resources');
    }
    if (responderBlocked) {
      reasons.unshift('responder-level block (see above)');
      compatible = false;
    }

    if (compatible) {
      console.log('  => COMPATIBLE');
    } else {
      console.log(`  => NOT COMPATIBLE — ${reasons.join('; ')}`);
    }
  }

  console.log('\nDone. (read-only diagnostic — no data was modified)');
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
