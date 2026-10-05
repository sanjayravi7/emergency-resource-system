'use strict';

/**
 * Explicit, auditable administrator bootstrap - the ONLY supported way to
 * create or promote an ERAS administrator. There is deliberately no public
 * registration route and no API endpoint that can mint an ADMIN: `role` is
 * always rejected by public signup, and this script must be run by an operator
 * who already has shell access to the deployment (Render shell / a trusted
 * workstation with the production DATABASE_URL).
 *
 * Two modes:
 *
 *   MODE=create  (default) create a brand new ADMIN account.
 *                Required: ERAS_ADMIN_NAME, ERAS_ADMIN_EMAIL,
 *                          ERAS_ADMIN_PASSWORD (min 12 characters).
 *                Refuses to touch an account that already exists.
 *
 *   MODE=promote promote an EXISTING account to ADMIN (never demotes, never
 *                creates). Identify it with ERAS_ADMIN_EMAIL or
 *                ERAS_ADMIN_USER_ID. Idempotent: an account that is already
 *                an active ADMIN is reported and left untouched.
 *
 * Every run needs NODE_ENV=production and an explicit confirmation token:
 *
 *   ERAS_CONFIRM_ADMIN_PROVISION=PROVISION_ONE_ADMIN   (MODE=create)
 *   ERAS_CONFIRM_ADMIN_PROVISION=PROMOTE_ONE_ADMIN     (MODE=promote)
 *
 * Set ERAS_ADMIN_DRY_RUN=1 to print the planned change without writing.
 *
 * Nothing secret is ever printed: no password, no hash, no DATABASE_URL.
 */

const bcrypt = require('bcrypt');
const { PrismaClient } = require('@prisma/client');

const prisma = new PrismaClient();

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

async function createAdmin({ name, email, password, dryRun }) {
  const existing = await prisma.user.findUnique({
    where: { email },
    select: { id: true, role: true },
  });
  if (existing) {
    throw new Error(
      `A user with ERAS_ADMIN_EMAIL already exists (id ${existing.id}, role ${existing.role}); no changes were made`
    );
  }

  if (dryRun) {
    return { dryRun: true, planned: `create ADMIN ${email}` };
  }

  const passwordHash = await bcrypt.hash(password, 12);
  const admin = await prisma.user.create({
    data: {
      name,
      email,
      password: passwordHash,
      role: 'ADMIN',
      isActive: true,
      emailVerified: true,
      emailVerifiedAt: new Date(),
    },
    select: { id: true, email: true, role: true },
  });
  return { created: true, admin };
}

async function promoteAdmin({ email, userId, dryRun }) {
  const where = email ? { email } : { id: userId };
  const user = await prisma.user.findUnique({
    where,
    select: { id: true, email: true, name: true, role: true, isActive: true, emailVerified: true },
  });
  if (!user) {
    throw new Error('No ERAS account matches ERAS_ADMIN_EMAIL / ERAS_ADMIN_USER_ID');
  }

  if (user.role === 'ADMIN' && user.isActive) {
    return { alreadyAdmin: true, user };
  }

  const data = {
    role: 'ADMIN',
    isActive: true,
    ...(user.emailVerified ? {} : { emailVerified: true, emailVerifiedAt: new Date() }),
  };

  if (dryRun) {
    return { dryRun: true, planned: `promote user ${user.id} (${user.email}) to ADMIN` };
  }

  const updated = await prisma.user.update({
    where: { id: user.id },
    data,
    select: { id: true, email: true, name: true, role: true, isActive: true },
  });
  return { promoted: true, before: user, user: updated };
}

async function main() {
  if (process.env.NODE_ENV !== 'production') {
    throw new Error('NODE_ENV must be production');
  }

  required('DATABASE_URL');

  const mode = (process.env.ERAS_ADMIN_MODE || 'create').trim().toLowerCase();
  const dryRun = /^(1|true|yes|on)$/i.test(String(process.env.ERAS_ADMIN_DRY_RUN || ''));
  const confirmation = String(process.env.ERAS_CONFIRM_ADMIN_PROVISION || '').trim();

  if (mode === 'promote') {
    if (confirmation !== 'PROMOTE_ONE_ADMIN') {
      throw new Error(
        'Set ERAS_CONFIRM_ADMIN_PROVISION=PROMOTE_ONE_ADMIN to confirm this one-time promotion'
      );
    }
    const email = process.env.ERAS_ADMIN_EMAIL?.trim().toLowerCase();
    const rawUserId = process.env.ERAS_ADMIN_USER_ID?.trim();
    const userId = rawUserId ? Number(rawUserId) : null;
    if (!email && (!Number.isInteger(userId) || userId <= 0)) {
      throw new Error('Set ERAS_ADMIN_EMAIL or a positive ERAS_ADMIN_USER_ID');
    }
    if (email && !/^\S+@\S+\.\S+$/.test(email)) {
      throw new Error('ERAS_ADMIN_EMAIL is invalid');
    }

    const result = await promoteAdmin({ email, userId, dryRun });
    if (result.dryRun) {
      console.log(`Dry run: ${result.planned}. No changes were made.`);
      return;
    }
    if (result.alreadyAdmin) {
      console.log(
        `User ${result.user.id} (${result.user.email}) is already an active ADMIN. No changes were made.`
      );
      return;
    }
    console.log(
      `Promoted user ${result.user.id} (${result.user.email}) from ${result.before.role} to ADMIN. No secret values were printed.`
    );
    return;
  }

  if (mode !== 'create') {
    throw new Error("ERAS_ADMIN_MODE must be 'create' or 'promote'");
  }

  if (confirmation !== 'PROVISION_ONE_ADMIN') {
    throw new Error(
      'Set ERAS_CONFIRM_ADMIN_PROVISION=PROVISION_ONE_ADMIN to confirm this one-time operation'
    );
  }

  const name = required('ERAS_ADMIN_NAME');
  const email = required('ERAS_ADMIN_EMAIL').toLowerCase();
  const password = required('ERAS_ADMIN_PASSWORD');

  if (!/^\S+@\S+\.\S+$/.test(email)) throw new Error('ERAS_ADMIN_EMAIL is invalid');
  if (password.length < 12) {
    throw new Error('ERAS_ADMIN_PASSWORD must be at least 12 characters');
  }

  const result = await createAdmin({ name, email, password, dryRun });
  if (result.dryRun) {
    console.log(`Dry run: ${result.planned}. No changes were made.`);
    return;
  }
  console.log(
    `Administrator created with user id ${result.admin.id}. No secret values were printed.`
  );
}

main()
  .catch((error) => {
    console.error(`Administrator provisioning failed: ${error.message}`);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
