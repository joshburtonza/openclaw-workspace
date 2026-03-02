-- ─────────────────────────────────────────────────────────────────────────────
-- 014_clients_authenticated_rls.sql
-- The clients table had only a TO anon policy, so authenticated users (Josh,
-- Salah) got empty results from the CSM page. Add authenticated read access.
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "authenticated_read_clients" ON clients;
CREATE POLICY "authenticated_read_clients"
  ON clients FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS "service_role_all_clients" ON clients;
CREATE POLICY "service_role_all_clients"
  ON clients FOR ALL TO service_role
  USING (true) WITH CHECK (true);
