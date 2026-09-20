-- CreateEnum
CREATE TYPE "UserRole" AS ENUM ('REQUESTER', 'RESPONDER', 'ADMIN');

-- CreateEnum
CREATE TYPE "ResponderStatus" AS ENUM ('AVAILABLE', 'BUSY', 'OFFLINE');

-- CreateEnum
CREATE TYPE "RequestStatus" AS ENUM ('PENDING', 'ACCEPTED', 'IN_PROGRESS', 'PARTIALLY_ALLOCATED', 'COMPLETED', 'CANCELLED');

-- CreateEnum
CREATE TYPE "Priority" AS ENUM ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL');

-- CreateEnum
CREATE TYPE "ResourceStatus" AS ENUM ('AVAILABLE', 'BUSY', 'UNAVAILABLE');

-- CreateEnum
CREATE TYPE "AllocationStatus" AS ENUM ('RESERVED', 'DISPATCHED', 'DELIVERED', 'CANCELLED');

-- CreateTable
CREATE TABLE "User" (
    "id" SERIAL NOT NULL,
    "name" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "password" TEXT NOT NULL,
    "phone" TEXT,
    "role" "UserRole" NOT NULL DEFAULT 'REQUESTER',
    "isActive" BOOLEAN NOT NULL DEFAULT true,
    "lastActiveAt" TIMESTAMP(3),
    "latitude" DOUBLE PRECISION,
    "longitude" DOUBLE PRECISION,
    "responderStatus" "ResponderStatus" NOT NULL DEFAULT 'OFFLINE',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "User_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "EmergencyRequest" (
    "id" SERIAL NOT NULL,
    "requesterId" INTEGER NOT NULL,
    "emergencyType" TEXT NOT NULL,
    "description" TEXT NOT NULL,
    "location" TEXT NOT NULL,
    "latitude" DOUBLE PRECISION,
    "longitude" DOUBLE PRECISION,
    "priority" "Priority" NOT NULL DEFAULT 'MEDIUM',
    "status" "RequestStatus" NOT NULL DEFAULT 'PENDING',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "EmergencyRequest_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Resource" (
    "id" SERIAL NOT NULL,
    "name" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "unit" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Resource_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ResponderResource" (
    "id" SERIAL NOT NULL,
    "responderId" INTEGER NOT NULL,
    "resourceId" INTEGER NOT NULL,
    "totalQuantity" INTEGER NOT NULL DEFAULT 0,
    "availableQuantity" INTEGER NOT NULL DEFAULT 0,
    "status" "ResourceStatus" NOT NULL DEFAULT 'UNAVAILABLE',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ResponderResource_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "RequestResource" (
    "id" SERIAL NOT NULL,
    "requestId" INTEGER NOT NULL,
    "resourceId" INTEGER NOT NULL,
    "quantity" INTEGER NOT NULL,

    CONSTRAINT "RequestResource_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Allocation" (
    "id" SERIAL NOT NULL,
    "requestId" INTEGER NOT NULL,
    "responderResourceId" INTEGER NOT NULL,
    "responderId" INTEGER NOT NULL,
    "resourceId" INTEGER NOT NULL,
    "quantity" INTEGER NOT NULL,
    "status" "AllocationStatus" NOT NULL DEFAULT 'RESERVED',
    "allocatedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Allocation_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "User_email_key" ON "User"("email");

-- CreateIndex
CREATE INDEX "EmergencyRequest_requesterId_idx" ON "EmergencyRequest"("requesterId");

-- CreateIndex
CREATE INDEX "EmergencyRequest_status_idx" ON "EmergencyRequest"("status");

-- CreateIndex
CREATE INDEX "EmergencyRequest_priority_idx" ON "EmergencyRequest"("priority");

-- CreateIndex
CREATE INDEX "EmergencyRequest_location_idx" ON "EmergencyRequest"("location");

-- CreateIndex
CREATE UNIQUE INDEX "Resource_name_key" ON "Resource"("name");

-- CreateIndex
CREATE INDEX "ResponderResource_responderId_idx" ON "ResponderResource"("responderId");

-- CreateIndex
CREATE INDEX "ResponderResource_resourceId_idx" ON "ResponderResource"("resourceId");

-- CreateIndex
CREATE INDEX "ResponderResource_status_idx" ON "ResponderResource"("status");

-- CreateIndex
CREATE UNIQUE INDEX "ResponderResource_responderId_resourceId_key" ON "ResponderResource"("responderId", "resourceId");

-- CreateIndex
CREATE INDEX "RequestResource_requestId_idx" ON "RequestResource"("requestId");

-- CreateIndex
CREATE INDEX "RequestResource_resourceId_idx" ON "RequestResource"("resourceId");

-- CreateIndex
CREATE UNIQUE INDEX "RequestResource_requestId_resourceId_key" ON "RequestResource"("requestId", "resourceId");

-- CreateIndex
CREATE INDEX "Allocation_requestId_idx" ON "Allocation"("requestId");

-- CreateIndex
CREATE INDEX "Allocation_responderResourceId_idx" ON "Allocation"("responderResourceId");

-- CreateIndex
CREATE INDEX "Allocation_responderId_idx" ON "Allocation"("responderId");

-- CreateIndex
CREATE INDEX "Allocation_resourceId_idx" ON "Allocation"("resourceId");

-- CreateIndex
CREATE INDEX "Allocation_status_idx" ON "Allocation"("status");

-- AddForeignKey
ALTER TABLE "EmergencyRequest" ADD CONSTRAINT "EmergencyRequest_requesterId_fkey" FOREIGN KEY ("requesterId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ResponderResource" ADD CONSTRAINT "ResponderResource_responderId_fkey" FOREIGN KEY ("responderId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ResponderResource" ADD CONSTRAINT "ResponderResource_resourceId_fkey" FOREIGN KEY ("resourceId") REFERENCES "Resource"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RequestResource" ADD CONSTRAINT "RequestResource_requestId_fkey" FOREIGN KEY ("requestId") REFERENCES "EmergencyRequest"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RequestResource" ADD CONSTRAINT "RequestResource_resourceId_fkey" FOREIGN KEY ("resourceId") REFERENCES "Resource"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Allocation" ADD CONSTRAINT "Allocation_requestId_fkey" FOREIGN KEY ("requestId") REFERENCES "EmergencyRequest"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Allocation" ADD CONSTRAINT "Allocation_responderResourceId_fkey" FOREIGN KEY ("responderResourceId") REFERENCES "ResponderResource"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Allocation" ADD CONSTRAINT "Allocation_responderId_fkey" FOREIGN KEY ("responderId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Allocation" ADD CONSTRAINT "Allocation_resourceId_fkey" FOREIGN KEY ("resourceId") REFERENCES "Resource"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
