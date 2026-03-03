-- ─────────────────────────────────────────────────────────────────────────────
-- 018_kill_switch.sql
-- Extends client_os_registry for the billing kill switch system.
-- AOS can pause any client individually via scripts/kill-switch.sh.
--
-- status:
--   active  → everything runs normally
--   paused  → outbound agents off, web app shows maintenance page
--   stopped → ALL agents off, web app blocked (most severe — use for non-payment)
--
-- retainer_status (already exists):
--   active   → invoice paid / retainer current
--   overdue  → invoice overdue (triggers pause)
--   cancelled → client terminated
--
-- Run in: AOS Supabase Dashboard → SQL Editor
-- ─────────────────────────────────────────────────────────────────────────────

-- Add pause_message column (shown on web app maintenance screen)
ALTER TABLE client_os_registry
  ADD COLUMN IF NOT EXISTS pause_message TEXT DEFAULT NULL;

-- Add webapp_paused boolean — web app kill switch (independent from OS agents)
-- Allows pausing just the app without touching OS agents, or vice versa
ALTER TABLE client_os_registry
  ADD COLUMN IF NOT EXISTS webapp_paused BOOLEAN DEFAULT false;

-- Add invoice_overdue_since — when did the invoice go overdue
ALTER TABLE client_os_registry
  ADD COLUMN IF NOT EXISTS invoice_overdue_since TIMESTAMPTZ DEFAULT NULL;

-- Seed all current clients (upsert — safe to re-run)
INSERT INTO client_os_registry (slug, name, status, monthly_amount, notes)
VALUES
  ('ascend_lc',         'Ascend LC (QMS Guard)',        'active', 0,     'Non-conformance management platform. No Mac Mini — web app + AOS hub tasks only.'),
  ('favorite_logistics','Favorite Logistics (FLAIR)',    'active', 0,     'Enterprise supply chain ERP. No Mac Mini — web app + AOS hub tasks only.'),
  ('metal_solutions',   'RT Metal / Luxe Living',       'active', 0,     'E-commerce site. Stale / low priority.')
ON CONFLICT (slug) DO UPDATE
  SET notes = EXCLUDED.notes;

-- Ensure Race Technik entry exists (already seeded in 003 but just in case)
INSERT INTO client_os_registry (slug, name, status, monthly_amount, notes)
VALUES
  ('race_technik', 'Race Technik', 'active', 21500, 'Race OS — chrome-auto-care + Mac Mini at 100.114.191.52')
ON CONFLICT (slug) DO NOTHING;

-- Index for fast slug lookups
CREATE INDEX IF NOT EXISTS idx_client_os_registry_slug ON client_os_registry(slug);
CREATE INDEX IF NOT EXISTS idx_client_os_registry_status ON client_os_registry(status);
