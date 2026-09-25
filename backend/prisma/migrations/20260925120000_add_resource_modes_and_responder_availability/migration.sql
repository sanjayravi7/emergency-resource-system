-- Add an explicit classification for reusable services and consumable stock.
-- Existing resources retain the inventory semantics they already had.
CREATE TYPE "ResourceMode" AS ENUM ('SERVICE', 'CONSUMABLE');

ALTER TABLE "Resource"
ADD COLUMN "mode" "ResourceMode" NOT NULL DEFAULT 'CONSUMABLE';
