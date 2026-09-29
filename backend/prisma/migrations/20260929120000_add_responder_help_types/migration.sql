-- Responder emergency-category eligibility is independent from resource
-- inventory. Existing Resource and ResponderResource rows are untouched.
CREATE TYPE "EmergencyCategory" AS ENUM (
  'FIRE',
  'MEDICAL',
  'ACCIDENT',
  'FLOOD',
  'RESCUE',
  'OTHER'
);

CREATE TABLE "ResponderHelpType" (
  "id" SERIAL NOT NULL,
  "responderId" INTEGER NOT NULL,
  "category" "EmergencyCategory" NOT NULL,
  "enabled" BOOLEAN NOT NULL DEFAULT true,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP(3) NOT NULL,

  CONSTRAINT "ResponderHelpType_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "ResponderHelpType_responderId_category_key"
  ON "ResponderHelpType"("responderId", "category");
CREATE INDEX "ResponderHelpType_responderId_enabled_idx"
  ON "ResponderHelpType"("responderId", "enabled");
CREATE INDEX "ResponderHelpType_category_enabled_idx"
  ON "ResponderHelpType"("category", "enabled");

ALTER TABLE "ResponderHelpType"
  ADD CONSTRAINT "ResponderHelpType_responderId_fkey"
  FOREIGN KEY ("responderId") REFERENCES "User"("id")
  ON DELETE CASCADE ON UPDATE CASCADE;
