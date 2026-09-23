/*
  Warnings:

  - You are about to drop the column `location` on the `User` table. All the data in the column will be lost.

*/
-- DropIndex
DROP INDEX "User_isActive_idx";

-- DropIndex
DROP INDEX "User_responderStatus_idx";

-- DropIndex
DROP INDEX "User_role_idx";

-- AlterTable
ALTER TABLE "EmergencyRequest" ADD COLUMN     "acceptedAt" TIMESTAMP(3),
ADD COLUMN     "acceptedById" INTEGER;

-- AlterTable
ALTER TABLE "User" DROP COLUMN "location";

-- CreateIndex
CREATE INDEX "EmergencyRequest_acceptedById_idx" ON "EmergencyRequest"("acceptedById");

-- AddForeignKey
ALTER TABLE "EmergencyRequest" ADD CONSTRAINT "EmergencyRequest_acceptedById_fkey" FOREIGN KEY ("acceptedById") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;
