-- ─────────────────────────────────────────────────────────────────────────────
-- 015_email_open_tracking.sql
-- Adds open tracking columns to outreach_log and a RPC function that the
-- Vercel pixel endpoint calls when an email is opened.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE outreach_log
  ADD COLUMN IF NOT EXISTS opened_at   TIMESTAMPTZ DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS open_count  INTEGER     NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS outreach_log_opened_at_idx ON outreach_log(opened_at)
  WHERE opened_at IS NOT NULL;

-- RPC called by the pixel endpoint (runs as service_role, no RLS bypass needed)
CREATE OR REPLACE FUNCTION log_email_open(log_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE outreach_log
  SET
    open_count = open_count + 1,
    opened_at  = COALESCE(opened_at, NOW())
  WHERE id = log_id;
END;
$$;

-- Allow the anon + service roles to call this function
GRANT EXECUTE ON FUNCTION log_email_open(UUID) TO anon, service_role;
