-- ─────────────────────────────────────────────────────────────────────────────
-- 007_crm_enrichment.sql
-- Adds proper enrichment schema to leads table for the Alex/AOS CRM.
-- Replaces text blobs (notes) with typed columns for Apollo data.
-- Adds multi-client support via a lightweight clients table.
--
-- Run in: Supabase Dashboard → SQL Editor
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Create clients table (CRM context: who do these leads belong to?) ─────

CREATE TABLE IF NOT EXISTS clients (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  slug       TEXT UNIQUE NOT NULL,
  color      TEXT DEFAULT '#4B9EFF',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- RLS
ALTER TABLE clients ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "service_role_all_clients" ON clients;
CREATE POLICY "service_role_all_clients"
  ON clients FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_read_clients" ON clients;
CREATE POLICY "anon_read_clients"
  ON clients FOR SELECT TO anon USING (true);

-- Seed known clients
INSERT INTO clients (name, slug) VALUES
  ('Amalfi AI (AOS)', 'aos'),
  ('Race Technik',    'race_technik'),
  ('Vanta Studios',   'vanta_studios')
ON CONFLICT (slug) DO NOTHING;

-- ── 2. Add enrichment columns to leads table ──────────────────────────────────

ALTER TABLE leads
  ADD COLUMN IF NOT EXISTS client_id        UUID REFERENCES clients(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS title            TEXT,
  ADD COLUMN IF NOT EXISTS linkedin_url     TEXT,
  ADD COLUMN IF NOT EXISTS apollo_id        TEXT,
  ADD COLUMN IF NOT EXISTS industry         TEXT,
  ADD COLUMN IF NOT EXISTS employee_count   INTEGER,
  ADD COLUMN IF NOT EXISTS location_city    TEXT,
  ADD COLUMN IF NOT EXISTS location_country TEXT,
  ADD COLUMN IF NOT EXISTS quality_score    INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS enriched_at      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS linkedin_status  TEXT DEFAULT NULL;

-- email_status already exists — skip

-- ── 3. Indexes ────────────────────────────────────────────────────────────────

-- Partial unique index on apollo_id (allows multiple NULLs)
CREATE UNIQUE INDEX IF NOT EXISTS leads_apollo_id_unique
  ON leads(apollo_id) WHERE apollo_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS leads_client_id_idx
  ON leads(client_id);

CREATE INDEX IF NOT EXISTS leads_quality_score_idx
  ON leads(quality_score DESC);

-- ── 4. Backfill: assign all existing leads to AOS client ──────────────────────

UPDATE leads
SET client_id = (SELECT id FROM clients WHERE slug = 'aos')
WHERE client_id IS NULL;
