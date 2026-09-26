-- CreateEnum
CREATE TYPE "AssignmentStatus" AS ENUM ('ACTIVE', 'ENDED');

-- CreateTable
CREATE TABLE "ResponderAssignment" (
    "id" SERIAL NOT NULL,
    "requestId" INTEGER NOT NULL,
    "responderId" INTEGER NOT NULL,
    "status" "AssignmentStatus" NOT NULL DEFAULT 'ACTIVE',
    "acceptedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "endedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ResponderAssignment_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "ResponderAssignment_requestId_responderId_key" ON "ResponderAssignment"("requestId", "responderId");

-- CreateIndex
CREATE INDEX "ResponderAssignment_requestId_status_idx" ON "ResponderAssignment"("requestId", "status");

-- CreateIndex
CREATE INDEX "ResponderAssignment_responderId_status_idx" ON "ResponderAssignment"("responderId", "status");

-- AddForeignKey
ALTER TABLE "ResponderAssignment" ADD CONSTRAINT "ResponderAssignment_requestId_fkey" FOREIGN KEY ("requestId") REFERENCES "EmergencyRequest"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ResponderAssignment" ADD CONSTRAINT "ResponderAssignment_responderId_fkey" FOREIGN KEY ("responderId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
