-- Preserve existing local accounts as verified; fresh email/password
-- registrations explicitly set emailVerified=false in authService.
ALTER TABLE "User"
  ADD COLUMN "emailVerified" BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN "firebaseUid" TEXT;

CREATE UNIQUE INDEX "User_firebaseUid_key" ON "User"("firebaseUid");

CREATE TYPE "AuthChallengePurpose" AS ENUM ('EMAIL_VERIFICATION', 'PASSWORD_RESET');

CREATE TABLE "AuthChallenge" (
  "id" SERIAL NOT NULL,
  "userId" INTEGER NOT NULL,
  "purpose" "AuthChallengePurpose" NOT NULL,
  "codeHash" TEXT NOT NULL,
  "expiresAt" TIMESTAMP(3) NOT NULL,
  "attempts" INTEGER NOT NULL DEFAULT 0,
  "consumedAt" TIMESTAMP(3),
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT "AuthChallenge_pkey" PRIMARY KEY ("id"),
  CONSTRAINT "AuthChallenge_userId_fkey"
    FOREIGN KEY ("userId") REFERENCES "User"("id")
    ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX "AuthChallenge_userId_purpose_createdAt_idx"
  ON "AuthChallenge"("userId", "purpose", "createdAt");
CREATE INDEX "AuthChallenge_expiresAt_idx"
  ON "AuthChallenge"("expiresAt");
