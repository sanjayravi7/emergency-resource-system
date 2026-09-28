'use strict';

/**
 * Explicit one-time production administrator bootstrap.
 *
 * This script never updates an existing user and never prints the password or
 * database URL. Run it only from a trusted workstation, then clear the three
 * ERAS_ADMIN_* variables from the shell.
 */

const bcrypt = require('bcrypt');
const { PrismaClient } = require('@prisma/client');

const prisma = new PrismaClient();

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

async function main() {
  if (process.env.NODE_ENV !== 'production') {
    throw new Error('NODE_ENV must be production');
  }
  if (process.env.ERAS_CONFIRM_ADMIN_PROVISION !== 'PROVISION_ONE_ADMIN') {
    throw new Error(
      'Set ERAS_CONFIRM_ADMIN_PROVISION=PROVISION_ONE_ADMIN to confirm this one-time operation'
    );
  }

  required('DATABASE_URL');
  const name = required('ERAS_ADMIN_NAME');
  const email = required('ERAS_ADMIN_EMAIL').toLowerCase();
  const password = required('ERAS_ADMIN_PASSWORD');

  if (!/^\S+@\S+\.\S+$/.test(email)) throw new Error('ERAS_ADMIN_EMAIL is invalid');
  if (password.length < 12) {
    throw new Error('ERAS_ADMIN_PASSWORD must be at least 12 characters');
  }

  const existing = await prisma.user.findUnique({ where: { email } });
  if (existing) {
    throw new Error('A user with ERAS_ADMIN_EMAIL already exists; no changes were made');
  }

  const passwordHash = await bcrypt.hash(password, 12);
  const admin = await prisma.user.create({
    data: {
      name,
      email,
      password: passwordHash,
      role: 'ADMIN',
      isActive: true,
    },
    select: { id: true },
  });

  console.log(`Administrator created with user id ${admin.id}. No secret values were printed.`);
}

main()
  .catch((error) => {
    console.error(`Administrator provisioning failed: ${error.message}`);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
