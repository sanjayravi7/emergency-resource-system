-- Corrective migration (append-only fix, does not edit any existing migration file).
--
-- The next migration in history, 20260925082623_add_responder_resource_willingness_and_delivery,
-- runs `DROP INDEX "ResponderResource_responderId_isEnabled_status_idx"` before that index is
-- ever created (it is only created later, in
-- 20260925090000_add_responder_resource_willingness_and_delivery, once the "isEnabled" column
-- exists). Applied in order on a fresh database this makes the DROP fail with
-- "index does not exist" before the feature migrations ever run.
--
-- To keep migration history append-only (no edits/deletions of existing migration files), this
-- migration creates a same-named placeholder index ahead of time so the later DROP has something
-- to drop. The placeholder is immediately dropped by the next migration and the real,
-- fully-specified index is (re)created by 20260925090000 once the "isEnabled" column exists, so
-- the net effect on a fresh database is unchanged from what those two migrations already intend.
CREATE INDEX "ResponderResource_responderId_isEnabled_status_idx"
ON "ResponderResource"("responderId");
