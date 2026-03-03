-- ─────────────────────────────────────────────────────────────────────────────
-- 019_finance_transactions.sql
-- Extends the existing finance_transactions table (created by the MC UI)
-- with FNB-poller columns: account_type, fnb_tx_id, balance_after, etc.
-- Run in: Supabase Dashboard → SQL Editor
-- ─────────────────────────────────────────────────────────────────────────────

-- Add new columns to existing table
ALTER TABLE finance_transactions
  ADD COLUMN IF NOT EXISTS account_type   TEXT DEFAULT 'business' CHECK (account_type IN ('business', 'personal')),
  ADD COLUMN IF NOT EXISTS reference      TEXT,
  ADD COLUMN IF NOT EXISTS balance_after  NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS fnb_tx_id      TEXT,
  ADD COLUMN IF NOT EXISTS merchant_name  TEXT,
  ADD COLUMN IF NOT EXISTS matched_client TEXT,
  ADD COLUMN IF NOT EXISTS matched_sub    TEXT,
  ADD COLUMN IF NOT EXISTS fx_fee         NUMERIC(8,2);

-- Unique constraint for upsert dedup (skip if already exists)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'finance_transactions_fnb_tx_id_key'
  ) THEN
    ALTER TABLE finance_transactions
      ADD CONSTRAINT finance_transactions_fnb_tx_id_key UNIQUE (fnb_tx_id);
  END IF;
END $$;

-- Indexes
CREATE INDEX IF NOT EXISTS finance_transactions_date_idx    ON finance_transactions(date DESC);
CREATE INDEX IF NOT EXISTS finance_transactions_type_idx    ON finance_transactions(type);
CREATE INDEX IF NOT EXISTS finance_transactions_account_idx ON finance_transactions(account_type);

-- Policies (idempotent)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'finance_transactions' AND policyname = 'service_role_all') THEN
    CREATE POLICY "service_role_all" ON finance_transactions
      FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'finance_transactions' AND policyname = 'authenticated_read') THEN
    CREATE POLICY "authenticated_read" ON finance_transactions
      FOR SELECT TO authenticated USING (true);
  END IF;
END $$;
