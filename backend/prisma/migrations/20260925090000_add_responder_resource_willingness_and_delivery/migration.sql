-- Add a durable responder willingness / qualification flag. Existing inventory
-- remains intact and intentionally starts disabled until the responder opts in.
ALTER TABLE "ResponderResource"
ADD COLUMN "isEnabled" BOOLEAN NOT NULL DEFAULT false;

-- Supports the availability helper's enabled-and-available lookup without
-- changing any existing model, relation, or historical allocation data.
CREATE INDEX "ResponderResource_responderId_isEnabled_status_idx"
ON "ResponderResource"("responderId", "isEnabled", "status");
