/**
 * Pre-test schema guard.
 *
 * `EmergencyRequest.description` is optional in schema.prisma. If the database
 * column is still NOT NULL (migration 20260926090000 never deployed), every
 * request without a description fails inside Prisma instead of being stored as
 * SQL NULL. This check turns that into an explicit, actionable message rather
 * than a confusing HTTP 400 during the integration tests.
 */

const prisma = require('../src/config/prisma');

async function main() {
  const rows = await prisma.$queryRaw`
    SELECT is_nullable
    FROM information_schema.columns
    WHERE table_name = 'EmergencyRequest' AND column_name = 'description'
  `;

  if (rows.length === 0) {
    throw new Error(
      'EmergencyRequest.description column not found. Run: npx prisma migrate deploy'
    );
  }

  if (rows[0].is_nullable !== 'YES') {
    throw new Error(
      'EmergencyRequest.description is still NOT NULL in the database.\n' +
        'Optional descriptions cannot be stored as NULL until the migration is applied.\n' +
        'Run: npx prisma migrate deploy'
    );
  }
}

main()
  .then(() => prisma.$disconnect())
  .catch(async (error) => {
    console.error(error.message);
    await prisma.$disconnect();
    process.exit(1);
  });
