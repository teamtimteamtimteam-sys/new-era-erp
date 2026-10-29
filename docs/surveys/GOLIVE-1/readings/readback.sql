-- GOLIVE-1 读回(抄自 COD-READERS 那一份,一次性账号的前缀加上 golive1probe):以 postgres(rolbypassrls)只数;对账那一句以 tim@(cfo)的身份,整笔回滚
SELECT 'PROOF|' || json_build_object(
  'users', (SELECT count(*) FROM auth.users),
  'enabled', (SELECT count(*) FROM auth.users WHERE banned_until IS NULL OR banned_until < now()),
  'throwaway_users', (SELECT count(*) FROM auth.users WHERE email ~ '^(codrprobe|golive1probe|survey|smoke)-'),
  'throwaway_roles', (SELECT count(*) FROM roles WHERE code LIKE 'probe-%'),
  'throwaway_suppliers', (SELECT count(*) FROM suppliers WHERE legal_name LIKE 'ZZ-PROBE golive1probe%'),
  'orphan_grants', (SELECT count(*) FROM user_roles ur WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ur.user_id)),
  'role_codes_held', (SELECT string_agg(DISTINCT r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.revoked_at IS NULL),
  'roles', (SELECT string_agg(r.code || ':' || (SELECT count(*) FROM role_permissions rp WHERE rp.role_id = r.id), ' ' ORDER BY r.code) FROM roles r),
  'approvals', (SELECT approvals_enabled FROM finance_settings LIMIT 1),
  'chain', (SELECT approval_level1_role_code || '/' || approval_level2_role_code || '/' || approval_threshold_base::int FROM finance_settings LIMIT 1),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings LIMIT 1),
  'cods', (SELECT count(*) FROM cod_issues),
  'cfo_grants_active', (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'cfo' AND ur.revoked_at IS NULL),
  'sup_2026_0003', (SELECT status || ' / ' || legal_name FROM suppliers WHERE code = 'SUP-2026-0003'),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f') AND has_table_privilege('anon', c.oid, 'SELECT')),
  'saved_views', (SELECT count(*) FROM saved_views))::text;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|recon ' || string_agg(s->>'side' || ' unexplained=' || COALESCE(s->>'unexplained_base', 'null') || ' agrees=' || COALESCE(s->>'agrees', 'null'), ' · ')
  FROM jsonb_array_elements((SELECT list_ledger_reconciliation())->'sides') s;
ROLLBACK;
