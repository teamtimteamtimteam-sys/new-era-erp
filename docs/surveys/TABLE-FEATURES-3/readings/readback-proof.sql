-- TABLE-FEATURES-3 证明之后的读回:以 postgres(rolbypassrls)只数;对账那一句以 tim@(cfo)的身份,整笔回滚。
-- Q4 要的两句:0 个一次性账号;除真的 cfo 持有人之外 0 条授 cfo 的 user_roles(未撤销的;撤销过的那一行 —— admin@ 的 2026-09-23 —— 照数,单列)。
SELECT 'PROOF|' || json_build_object(
  'users', (SELECT count(*) FROM auth.users),
  'enabled', (SELECT count(*) FROM auth.users WHERE banned_until IS NULL OR banned_until < now()),
  'throwaway_users', (SELECT count(*) FROM auth.users WHERE email ~ '^(tf2probe|tf3probe)-'),
  'throwaway_roles', (SELECT count(*) FROM roles WHERE code LIKE 'probe-%'),
  'orphan_grants', (SELECT count(*) FROM user_roles ur WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ur.user_id)),
  'cfo_grants_active_not_real_holder', (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                                          WHERE r.code = 'cfo' AND ur.revoked_at IS NULL AND ur.user_id <> '634c00f9-c3a9-4444-9eed-b624cb6a2a93'),
  'cfo_grants_active_real_holder', (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                                      WHERE r.code = 'cfo' AND ur.revoked_at IS NULL AND ur.user_id = '634c00f9-c3a9-4444-9eed-b624cb6a2a93'),
  'cfo_grants_all_rows', (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'cfo'),
  'role_codes_held', (SELECT string_agg(DISTINCT r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.revoked_at IS NULL),
  'approvals', (SELECT approvals_enabled FROM finance_settings LIMIT 1),
  'chain', (SELECT approval_level1_role_code || '/' || approval_level2_role_code || '/' || approval_threshold_base::int FROM finance_settings LIMIT 1),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings LIMIT 1),
  'cods', (SELECT count(*) FROM cod_issues),
  'saved_views_rows', (SELECT count(*) FROM saved_views),
  'journal_requests_rows', (SELECT count(*) FROM journal_requests),
  'leave_TF3', (SELECT count(*) FROM leave_requests WHERE code LIKE 'TF3PROOF%'),
  'employees_TF3', (SELECT count(*) FROM employees WHERE code LIKE 'TF3PROOF%'))::text;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|recon ' || string_agg(s->>'side' || ' unexplained=' || COALESCE(s->>'unexplained_base', 'null') || ' agrees=' || COALESCE(s->>'agrees', 'null'), ' · ')
  FROM jsonb_array_elements((SELECT list_ledger_reconciliation())->'sides') s;
ROLLBACK;
