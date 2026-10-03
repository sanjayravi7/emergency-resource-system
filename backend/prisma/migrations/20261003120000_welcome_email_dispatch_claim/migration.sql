-- Persistent at-most-once claim for ERAS welcome-email attempts.
-- NULL for accounts created before this migration and before their first
-- welcome-email event; populated atomically with email verification or Google
-- account creation before calling an external mail provider.
ALTER TABLE "User"
ADD COLUMN "welcomeEmailDispatchClaimedAt" TIMESTAMP(3);
