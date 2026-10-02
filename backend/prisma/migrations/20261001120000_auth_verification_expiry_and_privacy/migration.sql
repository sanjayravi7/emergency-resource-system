-- ERAS: Google/Firebase identity linking, email verification state, hashed
-- one-time codes (email verification + 6-digit password reset), an append-only
-- security audit trail, backend-authoritative request expiry and after-action
-- log archival.
--
-- SAFETY: purely additive. No existing column is dropped, renamed or made
-- NOT NULL, so the currently deployed application keeps working while this
-- migration is applied (prisma migrate deploy).
--
-- Existing accounts are backfilled as email-verified so nobody is locked out:
-- only accounts created AFTER this migration start unverified.

-- ---------------------------------------------------------------
-- New enums
-- ---------------------------------------------------------------
CREATE TYPE "AuthProvider" AS ENUM ('PASSWORD', 'GOOGLE');

CREATE TYPE "AuthCodePurpose" AS ENUM ('EMAIL_VERIFICATION', 'PASSWORD_RESET');

-- ---------------------------------------------------------------
-- User: verification state, Google/Firebase link, session epoch
-- ---------------------------------------------------------------
ALTER TABLE "User" ADD COLUMN "emailVerified" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "User" ADD COLUMN "emailVerifiedAt" TIMESTAMP(3);
ALTER TABLE "User" ADD COLUMN "authProvider" "AuthProvider" NOT NULL DEFAULT 'PASSWORD';
ALTER TABLE "User" ADD COLUMN "firebaseUid" TEXT;
ALTER TABLE "User" ADD COLUMN "passwordChangedAt" TIMESTAMP(3);

-- One Google/Firebase identity maps to at most one ERAS account. PostgreSQL
-- allows unlimited NULLs, so password-only accounts are unaffected.
CREATE UNIQUE INDEX "User_firebaseUid_key" ON "User"("firebaseUid");

-- Pre-existing accounts were created before verification existed and are
-- treated as verified (their email was already their credential).
UPDATE "User"
SET "emailVerified" = true,
    "emailVerifiedAt" = COALESCE("createdAt", CURRENT_TIMESTAMP)
WHERE "emailVerified" = false;

-- ---------------------------------------------------------------
-- EmergencyRequest: expiry + after-action archival
-- ---------------------------------------------------------------
ALTER TABLE "EmergencyRequest" ADD COLUMN "expiresAt" TIMESTAMP(3);
ALTER TABLE "EmergencyRequest" ADD COLUMN "expiredAt" TIMESTAMP(3);
ALTER TABLE "EmergencyRequest" ADD COLUMN "archivedAt" TIMESTAMP(3);
ALTER TABLE "EmergencyRequest" ADD COLUMN "archivedById" INTEGER;

CREATE INDEX "EmergencyRequest_status_expiresAt_idx"
  ON "EmergencyRequest"("status", "expiresAt");
CREATE INDEX "EmergencyRequest_archivedAt_idx"
  ON "EmergencyRequest"("archivedAt");

-- ---------------------------------------------------------------
-- AuthCode (hashed one-time codes)
-- ---------------------------------------------------------------
CREATE TABLE "AuthCode" (
  "id" SERIAL NOT NULL,
  "userId" INTEGER NOT NULL,
  "purpose" "AuthCodePurpose" NOT NULL,
  "codeHash" TEXT NOT NULL,
  "expiresAt" TIMESTAMP(3) NOT NULL,
  "attempts" INTEGER NOT NULL DEFAULT 0,
  "maxAttempts" INTEGER NOT NULL DEFAULT 5,
  "consumedAt" TIMESTAMP(3),
  "lastSentAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP(3) NOT NULL,

  CONSTRAINT "AuthCode_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "AuthCode_userId_purpose_idx" ON "AuthCode"("userId", "purpose");
CREATE INDEX "AuthCode_expiresAt_idx" ON "AuthCode"("expiresAt");

ALTER TABLE "AuthCode"
  ADD CONSTRAINT "AuthCode_userId_fkey"
  FOREIGN KEY ("userId") REFERENCES "User"("id")
  ON DELETE CASCADE ON UPDATE CASCADE;

-- ---------------------------------------------------------------
-- AuditLog (append-only; no secrets are ever stored here)
-- ---------------------------------------------------------------
CREATE TABLE "AuditLog" (
  "id" SERIAL NOT NULL,
  "event" TEXT NOT NULL,
  "actorId" INTEGER,
  "actorRole" TEXT,
  "targetType" TEXT,
  "targetId" TEXT,
  "ip" TEXT,
  "metadata" JSONB,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT "AuditLog_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "AuditLog_event_idx" ON "AuditLog"("event");
CREATE INDEX "AuditLog_actorId_idx" ON "AuditLog"("actorId");
CREATE INDEX "AuditLog_createdAt_idx" ON "AuditLog"("createdAt");

ALTER TABLE "AuditLog"
  ADD CONSTRAINT "AuditLog_actorId_fkey"
  FOREIGN KEY ("actorId") REFERENCES "User"("id")
  ON DELETE SET NULL ON UPDATE CASCADE;
