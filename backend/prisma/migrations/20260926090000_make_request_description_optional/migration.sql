-- Make emergency request descriptions optional while preserving all existing text.
ALTER TABLE "EmergencyRequest" ALTER COLUMN "description" DROP NOT NULL;
