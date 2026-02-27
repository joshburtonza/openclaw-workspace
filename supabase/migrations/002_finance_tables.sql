-- ─────────────────────────────────────────────────────────────────────────────
-- 002_finance_tables.sql
-- Creates subscriptions and finance_config tables used by Mission Control
-- Finances page.
-- Run in: Supabase Dashboard → SQL Editor
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS subscriptions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL,
  category       text NOT NULL DEFAULT 'business',    -- 'business' | 'personal'
  amount         numeric NOT NULL DEFAULT 0,
  currency       text NOT NULL DEFAULT 'ZAR',
  billing_cycle  text NOT NULL DEFAULT 'monthly',
  status         text NOT NULL DEFAULT 'active',       -- 'active' | 'cancelled'
  notes          text,
  created_at     timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS finance_config (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key        text UNIQUE NOT NULL,
  value      text NOT NULL,
  updated_at timestamptz DEFAULT now()
);

-- Seed Sajonix balance default (editable from Mission Control)
INSERT INTO finance_config (key, value)
VALUES ('sajonix_balance', '71000')
ON CONFLICT (key) DO NOTHING;

-- Enable RLS (optional — safe default for service role access)
ALTER TABLE subscriptions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE finance_config ENABLE ROW LEVEL SECURITY;

-- Allow service role full access
CREATE POLICY IF NOT EXISTS "service_role_all_subscriptions"
  ON subscriptions FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY IF NOT EXISTS "service_role_all_finance_config"
  ON finance_config FOR ALL TO service_role USING (true) WITH CHECK (true);
