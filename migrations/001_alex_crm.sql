-- ============================================================
-- 001_alex_crm.sql
-- Alex Cold Outreach CRM
-- Run once in Supabase SQL Editor → New Query → Run
-- ============================================================

-- LEADS — one row per prospect
CREATE TABLE IF NOT EXISTS leads (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name          TEXT NOT NULL,
  last_name           TEXT,
  email               TEXT NOT NULL,
  company             TEXT,
  website             TEXT,
  source              TEXT DEFAULT 'manual',
  -- manual | telegram | tiktok | referral | cold_list | linkedin
  status              TEXT DEFAULT 'new',
  -- new → contacted → replied → qualified → proposal → closed_won | closed_lost
  last_contacted_at   TIMESTAMPTZ,
  reply_received_at   TIMESTAMPTZ,
  reply_sentiment     TEXT,
  -- positive | neutral | negative | no_reply
  notes               TEXT,
  assigned_to         TEXT DEFAULT 'Josh',
  tags                TEXT[],
  created_at          TIMESTAMPTZ DEFAULT NOW(),
  updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Prevent exact email duplicates
CREATE UNIQUE INDEX IF NOT EXISTS leads_email_unique ON leads (LOWER(email));

-- Fast lookups
CREATE INDEX IF NOT EXISTS leads_status_idx        ON leads (status);
CREATE INDEX IF NOT EXISTS leads_last_contacted_idx ON leads (last_contacted_at);

-- OUTREACH_LOG — one row per email sent to a lead
CREATE TABLE IF NOT EXISTS outreach_log (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id          UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  step             INTEGER NOT NULL CHECK (step IN (1, 2, 3)),
  subject          TEXT,
  body             TEXT,
  sent_at          TIMESTAMPTZ DEFAULT NOW(),
  gmail_message_id TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS outreach_log_lead_idx ON outreach_log (lead_id);
CREATE INDEX IF NOT EXISTS outreach_log_sent_idx ON outreach_log (sent_at);

-- Auto-update updated_at on leads
CREATE OR REPLACE FUNCTION update_leads_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS leads_updated_at ON leads;
CREATE TRIGGER leads_updated_at
  BEFORE UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION update_leads_updated_at();

-- RLS: service role bypasses, anon can read (for MC dashboard)
ALTER TABLE leads         ENABLE ROW LEVEL SECURITY;
ALTER TABLE outreach_log  ENABLE ROW LEVEL SECURITY;

-- Allow anon read for Mission Control dashboard
DROP POLICY IF EXISTS "anon_read_leads"        ON leads;
DROP POLICY IF EXISTS "anon_read_outreach_log" ON outreach_log;

CREATE POLICY "anon_read_leads"
  ON leads FOR SELECT USING (true);

CREATE POLICY "anon_read_outreach_log"
  ON outreach_log FOR SELECT USING (true);

-- Service role gets full access (scripts use service role key)
-- (service role bypasses RLS by default in Supabase — no policy needed)
