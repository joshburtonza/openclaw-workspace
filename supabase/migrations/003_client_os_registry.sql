-- ─────────────────────────────────────────────────────────────────────────────
-- 003_client_os_registry.sql
-- Master registry of all AOS client instances.
-- Josh controls status from Mission Control or Telegram.
-- Each client machine polls this table every 5 min via client-os-daemon.sh.
-- Run in: Supabase Dashboard → SQL Editor
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS client_os_registry (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                text UNIQUE NOT NULL,      -- 'race_technik', 'vanta_studios'
  name                text NOT NULL,             -- 'Race Technik', 'Vanta Studios'
  status              text NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'paused', 'stopped')),
  last_heartbeat      timestamptz,               -- last time client phoned home
  mac_hostname        text,                      -- display only
  retainer_status     text DEFAULT 'active',     -- 'active' | 'overdue' | 'cancelled'
  monthly_amount      numeric DEFAULT 0,
  notes               text,
  status_changed_at   timestamptz DEFAULT now(),
  status_changed_by   text DEFAULT 'system',
  created_at          timestamptz DEFAULT now()
);

-- Seed existing clients
INSERT INTO client_os_registry (slug, name, status, monthly_amount, notes)
VALUES
  ('race_technik', 'Race Technik', 'active', 21500, 'Race OS — chrome-auto-care platform. Mac Mini via Tailscale 100.114.191.52'),
  ('vanta_studios', 'Vanta Studios', 'active', 0,    'Pending onboarding. SA print/photography B2B lead gen.')
ON CONFLICT (slug) DO NOTHING;

-- RLS
ALTER TABLE client_os_registry ENABLE ROW LEVEL SECURITY;

CREATE POLICY "service_role_all_client_os_registry"
  ON client_os_registry FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Anon read + heartbeat update only (for client daemons using anon key)
CREATE POLICY "anon_read_own_status"
  ON client_os_registry FOR SELECT TO anon USING (true);

-- Client can only update last_heartbeat + mac_hostname (not status)
-- Enforced at application level in the daemon
