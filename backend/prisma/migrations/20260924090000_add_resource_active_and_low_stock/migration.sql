-- AlterTable
-- Adds active/inactive state and low-stock visibility to the resource catalog.
-- Existing rows keep their data: every current resource stays active and gets
-- the default low stock threshold of 1.
ALTER TABLE "Resource" ADD COLUMN "isActive" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "Resource" ADD COLUMN "lowStockThreshold" INTEGER NOT NULL DEFAULT 1;

-- CreateIndex
CREATE INDEX "Resource_isActive_idx" ON "Resource"("isActive");
