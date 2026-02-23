-- ============================================================
-- 002_retainer_fields.sql
-- Adds project engagement tracking fields to the clients table.
-- Run once in Supabase SQL Editor → New Query → Run
--
-- NOTE: Currently tracked via data/client-projects.json (flat file).
-- Run this migration when ready to move tracking into Supabase.
-- After running: update email-response-scheduler.sh to read from
-- the clients table instead of data/client-projects.json.
-- ============================================================

ALTER TABLE clients
  ADD COLUMN IF NOT EXISTS project_start_date DATE,
  ADD COLUMN IF NOT EXISTS retainer_status    TEXT DEFAULT 'retainer';

-- retainer_status values:
--   'retainer'      — client is on a monthly retainer (default, existing clients)
--   'project_only'  — client is on a fixed-scope project with no ongoing retainer
--   'churned'       — client has ended engagement

-- Seed existing clients as retainer (they are already converted)
UPDATE clients
  SET retainer_status = 'retainer'
  WHERE retainer_status IS NULL;

-- Index for scheduler query performance
CREATE INDEX IF NOT EXISTS clients_retainer_status_idx
  ON clients (retainer_status);

CREATE INDEX IF NOT EXISTS clients_project_start_date_idx
  ON clients (project_start_date);

-- Comment the columns for documentation
COMMENT ON COLUMN clients.project_start_date IS
  'ISO date when the project engagement started. Used by email-response-scheduler to trigger retainer pitch at 60 days.';

COMMENT ON COLUMN clients.retainer_status IS
  'project_only = fixed-scope project, no retainer yet. retainer = on monthly retainer. churned = ended.';
