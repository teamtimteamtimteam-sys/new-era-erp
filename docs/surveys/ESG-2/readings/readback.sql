-- ESG-2 读回(线上证明与冒烟之后):以 postgres(rolbypassrls)只数;对账那一句以 tim@(cfo)身份,整笔回滚
SELECT 'PROOF|' || json_build_object(
  'users', (SELECT count(*) FROM auth.users),
  'enabled', (SELECT count(*) FROM auth.users WHERE banned_until IS NULL OR banned_until < now()),
  'throwaway_users', (SELECT count(*) FROM auth.users WHERE email ~ '^(esg2probe|survey|smoke)-'),
  'throwaway_roles', (SELECT count(*) FROM roles WHERE code LIKE 'probe-%'),
  'orphan_grants', (SELECT count(*) FROM user_roles ur WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ur.user_id)),
  'role_codes_held', (SELECT string_agg(DISTINCT r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.revoked_at IS NULL),
  'approvals', (SELECT approvals_enabled FROM finance_settings LIMIT 1),
  'chain', (SELECT approval_level1_role_code || '/' || approval_level2_role_code || '/' || approval_threshold_base::int FROM finance_settings LIMIT 1),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings LIMIT 1),
  'cods', (SELECT count(*) FROM cod_issues), 'view_cod_roles', (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'data.view_cod'),
  'cfo_grants_active', (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'cfo' AND ur.revoked_at IS NULL),
  'saved_views', (SELECT count(*) FROM saved_views), 'roles', (SELECT count(*) FROM roles),
  'esg_new_rows', json_build_object('factors', (SELECT count(*) FROM grid_emission_factors), 'hours', (SELECT COALESCE(standard_hours_per_day::text, 'NULL') FROM esg_settings),
     'required', (SELECT count(*) FROM required_trainings), 'policies', (SELECT count(*) FROM company_policies), 'reports', (SELECT count(*) FROM whistleblowing_reports),
     'updates', (SELECT count(*) FROM whistleblowing_updates), 'corrections', (SELECT count(*) FROM incident_days_lost_corrections)),
  'new_code_holders', (SELECT string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code IN ('action.manage_esg','data.view_whistleblowing','data.view_whistleblowing_escalated')))::text;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|recon ' || string_agg(s->>'side' || ' unexplained=' || COALESCE(s->>'unexplained_base', 'null') || ' agrees=' || COALESCE(s->>'agrees', 'null'), ' · ')
  FROM jsonb_array_elements((SELECT list_ledger_reconciliation())->'sides') s;
ROLLBACK;
