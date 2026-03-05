-- 010_leads_country.sql
-- Add country + email_status columns to leads for geo-aware outreach
-- Run in Supabase SQL Editor

ALTER TABLE leads ADD COLUMN IF NOT EXISTS country TEXT;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS email_status TEXT;

-- Index for geo-based queries
CREATE INDEX IF NOT EXISTS leads_country_idx ON leads (country);

COMMENT ON COLUMN leads.country IS 'ISO country or region name (e.g. South Africa, United Kingdom, United States). Used for geo-aware outreach tone.';
