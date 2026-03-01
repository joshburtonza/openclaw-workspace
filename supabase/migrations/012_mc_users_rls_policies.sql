-- ─────────────────────────────────────────────────────────────────────────────
-- 012_mc_users_rls_policies.sql
-- RLS policies for mc_users table.
-- 011_mc_auth.sql created the table + enabled RLS but policies were never
-- applied to the live DB, blocking authenticated users from reading their row.
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "service_role_all_mc_users" ON mc_users;
CREATE POLICY "service_role_all_mc_users"
  ON mc_users FOR ALL TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "users_read_own_mc_users" ON mc_users;
CREATE POLICY "users_read_own_mc_users"
  ON mc_users FOR SELECT TO authenticated
  USING ((auth.jwt() ->> 'email') = email);

-- subscriptions and finance_config: authenticated users need full access
-- (app-level auth guard handles who can see what)
DROP POLICY IF EXISTS "authenticated_all_subscriptions" ON subscriptions;
CREATE POLICY "authenticated_all_subscriptions"
  ON subscriptions FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "authenticated_all_finance_config" ON finance_config;
CREATE POLICY "authenticated_all_finance_config"
  ON finance_config FOR ALL TO authenticated
  USING (true) WITH CHECK (true);
