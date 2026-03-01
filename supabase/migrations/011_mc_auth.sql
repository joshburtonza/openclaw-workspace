-- ─────────────────────────────────────────────────────────────────────────────
-- 011_mc_auth.sql
-- Multi-tenant user table for Mission Control.
-- Maps authenticated Supabase users to roles + page permissions.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS mc_users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         TEXT UNIQUE NOT NULL,
  role          TEXT NOT NULL DEFAULT 'staff', -- 'owner' | 'staff'
  display_name  TEXT,
  allowed_pages TEXT[] DEFAULT ARRAY['/finances']::TEXT[],
  created_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE mc_users ENABLE ROW LEVEL SECURITY;

-- Service role can do everything (for admin scripts)
DROP POLICY IF EXISTS "service_role_all_mc_users" ON mc_users;
CREATE POLICY "service_role_all_mc_users"
  ON mc_users FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Authenticated users can only read their own row
DROP POLICY IF EXISTS "users_read_own_mc_users" ON mc_users;
CREATE POLICY "users_read_own_mc_users"
  ON mc_users FOR SELECT TO authenticated
  USING (auth.email() = email);

-- ── Seed users ────────────────────────────────────────────────────────────────

-- Josh: owner, sees everything
INSERT INTO mc_users (email, role, display_name, allowed_pages) VALUES
  ('josh@amalfiai.com', 'owner', 'Josh', ARRAY['*']::TEXT[])
ON CONFLICT (email) DO NOTHING;

-- Salah: staff, sees business finances only
-- UPDATE THE EMAIL BELOW to Salah's real email, then run:
-- INSERT INTO mc_users (email, role, display_name, allowed_pages) VALUES
--   ('salah@example.com', 'staff', 'Salah', ARRAY['/finances']::TEXT[])
-- ON CONFLICT (email) DO NOTHING;
