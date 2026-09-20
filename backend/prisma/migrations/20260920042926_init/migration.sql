/*
  Warnings:

  - Added the required column `updatedAt` to the `Resource` table without a default value. This is not possible if the table is not empty.

*/
-- AlterTable
ALTER TABLE "Resource" ADD COLUMN     "availableQuantity" INTEGER NOT NULL DEFAULT 0,
ADD COLUMN     "location" TEXT,
ADD COLUMN     "totalQuantity" INTEGER NOT NULL DEFAULT 0,
ADD COLUMN     "updatedAt" TIMESTAMP(3) NOT NULL;

-- AlterTable
ALTER TABLE "User" ADD COLUMN     "location" TEXT;

-- CreateIndex
CREATE INDEX "Resource_type_idx" ON "Resource"("type");

-- CreateIndex
CREATE INDEX "Resource_location_idx" ON "Resource"("location");

-- CreateIndex
CREATE INDEX "User_role_idx" ON "User"("role");

-- CreateIndex
CREATE INDEX "User_responderStatus_idx" ON "User"("responderStatus");

-- CreateIndex
CREATE INDEX "User_isActive_idx" ON "User"("isActive");
