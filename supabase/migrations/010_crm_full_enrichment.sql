-- ─────────────────────────────────────────────────────────────────────────────
-- 010_crm_full_enrichment.sql
-- Adds every remaining Apollo field we can pull on the starter plan.
-- Org: logo, phone, alexa rank, facebook, angellist, dept headcount,
--      market cap, public co, languages, funding data.
-- Person: photo, city, country, timezone.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE leads
  -- Company display
  ADD COLUMN IF NOT EXISTS logo_url               TEXT,
  ADD COLUMN IF NOT EXISTS company_phone          TEXT,
  ADD COLUMN IF NOT EXISTS alexa_ranking          INTEGER,
  ADD COLUMN IF NOT EXISTS facebook_url           TEXT,
  ADD COLUMN IF NOT EXISTS angellist_url          TEXT,

  -- Company structure
  ADD COLUMN IF NOT EXISTS dept_head_count        JSONB,
  ADD COLUMN IF NOT EXISTS company_languages      TEXT[],

  -- Public company
  ADD COLUMN IF NOT EXISTS market_cap             TEXT,
  ADD COLUMN IF NOT EXISTS publicly_traded_symbol TEXT,
  ADD COLUMN IF NOT EXISTS publicly_traded_exchange TEXT,

  -- Funding
  ADD COLUMN IF NOT EXISTS total_funding          TEXT,
  ADD COLUMN IF NOT EXISTS latest_funding_stage   TEXT,
  ADD COLUMN IF NOT EXISTS funding_events         JSONB,

  -- Person
  ADD COLUMN IF NOT EXISTS photo_url              TEXT,
  ADD COLUMN IF NOT EXISTS person_city            TEXT,
  ADD COLUMN IF NOT EXISTS person_country         TEXT,
  ADD COLUMN IF NOT EXISTS person_timezone        TEXT;
