-- CreateEnum
-- SERVICE resources (e.g. Ambulance, Volunteer, Fire Resource, Rescue Boat)
-- are reusable responder capabilities. CONSUMABLE resources (e.g. Blood,
-- Oxygen, Water, Medicine) are spent from inventory. Business logic branches
-- on this column and never infers mode from a resource name.
CREATE TYPE "ResourceMode" AS ENUM ('SERVICE', 'CONSUMABLE');

-- AlterTable
-- Defaults to CONSUMABLE so every existing resource keeps its current
-- inventory-driven behaviour. totalQuantity and availableQuantity are
-- untouched and remain required for CONSUMABLE inventory tracking.
ALTER TABLE "Resource" ADD COLUMN     "mode" "ResourceMode" NOT NULL DEFAULT 'CONSUMABLE';
