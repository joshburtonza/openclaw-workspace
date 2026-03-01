-- ─────────────────────────────────────────────────────────────────────────────
-- 009_crm_company_intel.sql
-- Adds company intelligence + person seniority columns to leads table.
-- Populated by the updated enrich-leads.sh via Apollo org enrichment.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE leads
  ADD COLUMN IF NOT EXISTS company_description   TEXT,
  ADD COLUMN IF NOT EXISTS tech_stack            TEXT[],
  ADD COLUMN IF NOT EXISTS company_keywords      TEXT[],
  ADD COLUMN IF NOT EXISTS twitter_url           TEXT,
  ADD COLUMN IF NOT EXISTS company_linkedin_url  TEXT,
  ADD COLUMN IF NOT EXISTS annual_revenue        TEXT,
  ADD COLUMN IF NOT EXISTS founded_year          INTEGER,
  ADD COLUMN IF NOT EXISTS seniority             TEXT,
  ADD COLUMN IF NOT EXISTS headline              TEXT,
  ADD COLUMN IF NOT EXISTS departments           TEXT[];
