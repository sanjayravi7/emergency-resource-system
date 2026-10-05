#!/usr/bin/env node
'use strict';

/**
 * READ-ONLY inspection of one ERAS account and its operational history.
 *
 * Use this BEFORE deleting anything. "Stale" rows in the responders list are
 * usually accounts that participated in an emergency; deleting them would
 * destroy history that ERAS needs for its after-action log and allocations.
 *
 * The script NEVER writes: it only reads and prints what an administrator may
 * safely do next (rename / deactivate / delete).
 *
 * Usage (run from the backend directory, with DATABASE_URL configured):
 *
 *   node scripts/inspect-user.js --id 8
 *   node scripts/inspect-user.js --email indexceramic2018@gmail.com
 *
 * Exit codes: 0 = found (verdict printed), 1 = not found / bad arguments.
 */

const { PrismaClient } = require('@prisma/client');

const prisma = new PrismaClient();

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) continue;
    const [name, inlineValue] = token.slice(2).split('=');
    if (inlineValue !== undefined) {
      args[name] = inlineValue;
    } else {
      args[name] = argv[index + 1] && !argv[index + 1].startsWith('--')
        ? argv[++index]
        : 'true';
    }
  }
  return args;
}

function printLine(label, value) {
  console.log(`  ${label.padEnd(30)} ${value}`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const id = args.id ? Number(args.id) : null;
  const email = args.email ? String(args.email).trim().toLowerCase() : null;

  if ((!id || !Number.isInteger(id) || id <= 0) && !email) {
    throw new Error('Provide --id <userId> or --email <address>');
  }

  const user = await prisma.user.findUnique({
    where: id ? { id } : { email },
    select: {
      id: true,
      name: true,
      email: true,
      phone: true,
      role: true,
      isActive: true,
      responderStatus: true,
      emailVerified: true,
      authProvider: true,
      firebaseUid: true,
      location: true,
      lastActiveAt: true,
      createdAt: true,
      updatedAt: true,
    },
  });

  if (!user) {
    console.log('No ERAS account matches that identifier. Nothing was changed.');
    process.exitCode = 1;
    return;
  }

  const [requested, accepted, assignments, allocations, inventory, helpTypes, authCodes, deviceTokens, auditRows] =
    await Promise.all([
      prisma.emergencyRequest.findMany({
        where: { requesterId: user.id },
        select: { id: true, status: true, archivedAt: true },
      }),
      prisma.emergencyRequest.findMany({
        where: { acceptedById: user.id },
        select: { id: true, status: true },
      }),
      prisma.responderAssignment.findMany({
        where: { responderId: user.id },
        select: { id: true, requestId: true, status: true },
      }),
      prisma.allocation.findMany({
        where: { responderId: user.id },
        select: { id: true, requestId: true, status: true, quantity: true },
      }),
      prisma.responderResource.findMany({
        where: { responderId: user.id },
        select: { id: true, resourceId: true, totalQuantity: true, isEnabled: true },
      }),
      prisma.responderHelpType.findMany({
        where: { responderId: user.id },
        select: { id: true, category: true, enabled: true },
      }),
      prisma.authCode.findMany({
        where: { userId: user.id },
        select: { id: true, purpose: true, consumedAt: true },
      }),
      prisma.pushDeviceToken.count({ where: { userId: user.id } }),
      prisma.auditLog.count({ where: { actorId: user.id } }),
    ]);

  const byStatus = (rows) =>
    rows.reduce((acc, row) => {
      acc[row.status] = (acc[row.status] || 0) + 1;
      return acc;
    }, {});

  const formatCounts = (counts) =>
    Object.keys(counts).length ? JSON.stringify(counts) : '0';

  console.log('');
  console.log(`ERAS account #${user.id} (read-only inspection)`);
  console.log('─'.repeat(64));
  printLine('name', user.name);
  printLine('email', user.email);
  printLine('phone', user.phone ?? '-');
  printLine('role', user.role);
  printLine('active', user.isActive ? 'yes' : 'NO (deactivated)');
  printLine('responder status', user.responderStatus);
  printLine('email verified', user.emailVerified ? 'yes' : 'no');
  printLine('auth provider', user.authProvider);
  printLine('firebase uid linked', user.firebaseUid ? 'yes' : 'no');
  printLine('last active at', user.lastActiveAt?.toISOString() ?? '-');
  printLine('created at', user.createdAt.toISOString());

  console.log('');
  console.log('Operational relationships');
  console.log('─'.repeat(64));
  printLine('emergencies requested', `${requested.length} ${formatCounts(byStatus(requested))}`);
  printLine('emergencies accepted (lead)', `${accepted.length} ${formatCounts(byStatus(accepted))}`);
  printLine('responder assignments', `${assignments.length} ${formatCounts(byStatus(assignments))}`);
  printLine('allocations', `${allocations.length} ${formatCounts(byStatus(allocations))}`);
  printLine('inventory rows', String(inventory.length));
  printLine('help types', String(helpTypes.length));
  printLine('one-time auth codes', String(authCodes.length));
  printLine('push device tokens', String(deviceTokens));
  printLine('audit rows as actor', String(auditRows));

  const historyTotal =
    requested.length +
    accepted.length +
    assignments.length +
    allocations.length +
    inventory.length +
    helpTypes.length;

  console.log('');
  console.log('Verdict');
  console.log('─'.repeat(64));
  if (historyTotal > 0) {
    console.log('  PRESERVE this account: it is linked to ERAS history.');
    console.log('  Deleting it is refused by the API and would orphan rows in');
    console.log('  EmergencyRequest / ResponderAssignment / Allocation.');
    console.log('');
    console.log('  Safe operations, in order of preference:');
    console.log('    1. Correct the display name (keeps every record intact):');
    console.log(`       PATCH /api/users/${user.id}   { "name": "<correct name>" }`);
    console.log('    2. Stop the account from signing in (history preserved):');
    console.log(`       PATCH /api/users/${user.id}/deactivate`);
    console.log('    3. Hide it from the responder directory: the directory only');
    console.log('       lists ACTIVE responders, so deactivation is enough.');
    console.log('');
    console.log('  (Equivalent SQL, only if you must act directly on PostgreSQL:)');
    console.log(`     UPDATE "User" SET name = '<correct name>' WHERE id = ${user.id};`);
    console.log(`     UPDATE "User" SET "isActive" = false, "responderStatus" = 'OFFLINE' WHERE id = ${user.id};`);
  } else {
    console.log('  This account has NO emergency, assignment, allocation or');
    console.log('  inventory history, so it is safe to remove.');
    console.log('');
    console.log('  Preferred (audited, guarded) API call as an ADMIN:');
    console.log(`     DELETE /api/users/${user.id}   { "confirm": true }`);
    console.log('');
    console.log('  The endpoint still refuses to delete the last active ADMIN and');
    console.log('  re-checks the counters inside the transaction. Deactivating is');
    console.log('  always the reversible alternative:');
    console.log(`     PATCH /api/users/${user.id}/deactivate`);
  }
  console.log('');
}

main()
  .catch((error) => {
    console.error(`User inspection failed: ${error.message}`);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
