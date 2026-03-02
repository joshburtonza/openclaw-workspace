-- ─────────────────────────────────────────────────────────────────────────────
-- 016_outreach_tracking_id.sql
-- Adds gog CF Worker tracking_id to outreach_log so the open poller
-- can query gog gmail track opens <tracking_id> per sent email.
-- Also adds opened_at / open_count from migration 015 in one shot
-- (run 015 and 016 together if you haven't applied 015 yet).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE outreach_log
  ADD COLUMN IF NOT EXISTS tracking_id  TEXT         DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS opened_at    TIMESTAMPTZ  DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS open_count   INTEGER      NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS outreach_log_tracking_id_idx ON outreach_log(tracking_id)
  WHERE tracking_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS outreach_log_opened_at_idx ON outreach_log(opened_at)
  WHERE opened_at IS NOT NULL;

-- RPC called by the Vercel fallback pixel endpoint
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

GRANT EXECUTE ON FUNCTION log_email_open(UUID) TO anon, service_role;
