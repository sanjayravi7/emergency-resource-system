/**
 * Development seed data.
 *
 * Safe to run repeatedly:
 *  - resources are upserted by their unique name (never duplicated)
 *  - users are upserted by their unique email
 *  - responder inventory is upserted by (responderId, resourceId)
 *
 * No resource ID is ever hardcoded - resources are looked up by name/type.
 *
 * Run with:  npm run seed      (or: npx prisma db seed)
 */

const prisma = require('../src/config/prisma');

let bcrypt;
try {
  // bcrypt is a devDependency; the seed is a development-only script.
  bcrypt = require('bcrypt');
} catch (error) {
  bcrypt = null;
}

const DEV_PASSWORD = 'Test@12345';

// Preferred development responder id (see PHASE 15 of the brief).
// If that id is not a responder in this database we fall back to the
// seeded responder account - the id is never assumed to exist.
const PREFERRED_RESPONDER_ID = 49;

// SERVICE resources are reusable responder capabilities (unlimited sequential
// use, gated only by the responder's current availability). CONSUMABLE
// resources are spent from inventory. These example names are seed data
// only - no service code branches on a resource name or type string.
const RESOURCES = [
  {
    name: 'Ambulance',
    type: 'AMBULANCE',
    mode: 'SERVICE',
    totalQuantity: 10,
    availableQuantity: 10,
    unit: 'vehicle',
    location: 'Central Depot',
    lowStockThreshold: 2,
  },
  {
    name: 'Volunteer',
    type: 'VOLUNTEER',
    mode: 'SERVICE',
    totalQuantity: 10,
    availableQuantity: 10,
    unit: 'person',
    location: 'Community Hall',
    lowStockThreshold: 2,
  },
  {
    name: 'Fire Resource',
    type: 'FIRE',
    mode: 'SERVICE',
    totalQuantity: 10,
    availableQuantity: 10,
    unit: 'unit',
    location: 'Fire Station 1',
    lowStockThreshold: 2,
  },
  {
    name: 'Rescue Boat',
    type: 'RESCUE_BOAT',
    mode: 'SERVICE',
    totalQuantity: 5,
    availableQuantity: 5,
    unit: 'vessel',
    location: 'Harbor Station',
    lowStockThreshold: 1,
  },
  {
    name: 'Blood',
    type: 'BLOOD',
    mode: 'CONSUMABLE',
    totalQuantity: 10,
    availableQuantity: 10,
    unit: 'unit',
    location: 'Central Blood Bank',
    lowStockThreshold: 2,
  },
  {
    name: 'Oxygen',
    type: 'OXYGEN',
    mode: 'CONSUMABLE',
    totalQuantity: 20,
    availableQuantity: 20,
    unit: 'cylinder',
    location: 'Central Depot',
    lowStockThreshold: 4,
  },
  {
    name: 'Water',
    type: 'WATER',
    mode: 'CONSUMABLE',
    totalQuantity: 50,
    availableQuantity: 50,
    unit: 'bottle',
    location: 'Central Depot',
    lowStockThreshold: 10,
  },
  {
    name: 'Medicine',
    type: 'MEDICINE',
    mode: 'CONSUMABLE',
    totalQuantity: 30,
    availableQuantity: 30,
    unit: 'kit',
    location: 'Central Pharmacy',
    lowStockThreshold: 5,
  },
];

async function hashPassword(plain) {
  if (!bcrypt) return plain;
  return await bcrypt.hash(plain, 10);
}

async function upsertResources() {
  const resources = [];

  for (const resource of RESOURCES) {
    const row = await prisma.resource.upsert({
      where: { name: resource.name },
      // Keep live quantities intact on re-runs - only make sure the
      // resource is usable (active, typed, measurable).
      update: {
        type: resource.type,
        mode: resource.mode,
        unit: resource.unit,
        location: resource.location,
        lowStockThreshold: resource.lowStockThreshold,
        isActive: true,
      },
      create: resource,
    });

    resources.push(row);
  }

  return resources;
}

async function upsertUser({ email, name, role, phone, location, extra = {} }) {
  const password = await hashPassword(DEV_PASSWORD);

  return await prisma.user.upsert({
    where: { email },
    update: {
      name,
      role,
      phone,
      location,
      isActive: true,
      ...extra,
    },
    create: {
      email,
      name,
      role,
      phone,
      location,
      password,
      isActive: true,
      ...extra,
    },
  });
}

async function resolveDevResponder() {
  // Prefer the existing development responder (id 49) when it really is a
  // responder in this database.
  const preferred = await prisma.user.findUnique({
    where: { id: PREFERRED_RESPONDER_ID },
  });

  if (preferred && preferred.role === 'RESPONDER') {
    return await prisma.user.update({
      where: { id: preferred.id },
      data: {
        isActive: true,
        responderStatus: 'AVAILABLE',
        phone: preferred.phone || '9000000049',
        location: preferred.location || 'North Ridge',
      },
    });
  }

  return await upsertUser({
    email: 'responder49@eras.dev',
    name: 'Responder1',
    role: 'RESPONDER',
    phone: '9000000049',
    location: 'North Ridge',
    extra: {
      responderStatus: 'AVAILABLE',
      latitude: 10.5276,
      longitude: 76.2144,
    },
  });
}

async function upsertResponderInventory(responderId, resources) {
  // Give the development responder capability for EVERY standard resource in
  // the catalog so multi-resource compatibility (e.g. Blood + Fire Resource)
  // can actually be tested end to end.
  //
  // Resource ids are never hardcoded - each capability is looked up by the
  // resource NAME and the actual PostgreSQL id is used for the upsert.
  //
  // On re-run we intentionally RESTORE totalQuantity / availableQuantity /
  // status. That makes the seed self-healing: if a development responder ever
  // ends up with a depleted, UNAVAILABLE, or missing inventory row (the exact
  // situation that hides a pending request from the dispatch board), running
  // the seed again puts the inventory back into a known-good AVAILABLE state.
  const capabilities = {
    // SERVICE resources: quantity is irrelevant (never decremented). Kept at
    // 1/1 so the responder still shows a non-zero inventory row.
    Ambulance: { totalQuantity: 1, availableQuantity: 1 },
    'Fire Resource': { totalQuantity: 1, availableQuantity: 1 },
    Volunteer: { totalQuantity: 1, availableQuantity: 1 },
    'Rescue Boat': { totalQuantity: 1, availableQuantity: 1 },
    // CONSUMABLE resources: real spendable inventory.
    Blood: { totalQuantity: 10, availableQuantity: 10 },
    Oxygen: { totalQuantity: 10, availableQuantity: 10 },
    Water: { totalQuantity: 20, availableQuantity: 20 },
    Medicine: { totalQuantity: 15, availableQuantity: 15 },
  };

  const inventory = [];

  for (const resource of resources) {
    const capability = capabilities[resource.name];
    if (!capability) continue;

    const row = await prisma.responderResource.upsert({
      where: {
        responderId_resourceId: {
          responderId,
          resourceId: resource.id,
        },
      },
      update: {
        totalQuantity: capability.totalQuantity,
        availableQuantity: capability.availableQuantity,
        isEnabled: true,
        status: 'AVAILABLE',
      },
      create: {
        responderId,
        resourceId: resource.id,
        totalQuantity: capability.totalQuantity,
        availableQuantity: capability.availableQuantity,
        isEnabled: true,
        status: 'AVAILABLE',
      },
    });

    inventory.push({ resource, row });
  }

  return inventory;
}

async function main() {
  const resources = await upsertResources();

  console.log('Resources ready:');
  for (const resource of resources) {
    console.log(
      `  #${resource.id} ${resource.name} (${resource.type}) ` +
        `${resource.availableQuantity}/${resource.totalQuantity} ${resource.unit || ''}`
    );
  }

  const requester = await upsertUser({
    email: 'requester@eras.dev',
    name: 'Arun',
    role: 'REQUESTER',
    phone: '9000000001',
    location: 'North Ridge',
  });

  const admin = await upsertUser({
    email: 'admin@eras.dev',
    name: 'ERAS Admin',
    role: 'ADMIN',
    phone: '9000000002',
    location: 'Control Room',
  });

  const responder = await resolveDevResponder();

  const inventory = await upsertResponderInventory(responder.id, resources);

  console.log(
    `\nResponder #${responder.id} inventory (status ${responder.responderStatus}):`
  );
  for (const { resource, row } of inventory) {
    console.log(
      `  ${resource.name.padEnd(15)} ${row.availableQuantity}/${row.totalQuantity} ${row.status}`
    );
  }

  console.log('\nDevelopment accounts (password: %s)', DEV_PASSWORD);
  console.log(`  REQUESTER #${requester.id} ${requester.email}`);
  console.log(`  RESPONDER #${responder.id} ${responder.email} (AVAILABLE)`);
  console.log(`  ADMIN     #${admin.id} ${admin.email}`);

  if (responder.id !== PREFERRED_RESPONDER_ID) {
    console.log(
      `\nNote: user #${PREFERRED_RESPONDER_ID} is not a RESPONDER in this database, ` +
        `so responder #${responder.id} was seeded instead.`
    );
  }
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
