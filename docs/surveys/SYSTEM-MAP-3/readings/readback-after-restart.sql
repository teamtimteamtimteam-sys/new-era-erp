-- SYSTEM-MAP-3 · 重启之后的读回(Tim 2026-10-27 23:05 第 2 步)。以 postgres 只数;对账以 tim@(cfo)身份、整笔回滚
SELECT 'PROOF|' || json_build_object(
  'users', (SELECT count(*) FROM auth.users),
  'enabled', (SELECT count(*) FROM auth.users WHERE banned_until IS NULL OR banned_until < now()),
  'throwaway_users', (SELECT count(*) FROM auth.users WHERE email ~ '^(tf1probe|tf2probe|tf3probe|sm1probe|sm2probe|sm3probe|survey|smoke)-'),
  'throwaway_roles', (SELECT count(*) FROM roles WHERE code LIKE 'probe-%'),
  'orphan_grants', (SELECT count(*) FROM user_roles ur WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ur.user_id)),
  'role_grants', (SELECT string_agg(r.code || ':' || cnt, ',' ORDER BY r.code) FROM (SELECT role_id, count(*) cnt FROM user_roles WHERE revoked_at IS NULL GROUP BY 1) g JOIN roles r ON r.id = g.role_id),
  'approvals', (SELECT approvals_enabled FROM finance_settings LIMIT 1),
  'chain', (SELECT approval_level1_role_code || '/' || approval_level2_role_code || '/' || approval_threshold_base::int FROM finance_settings LIMIT 1),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings LIMIT 1),
  'cods', (SELECT count(*) FROM cod_issues),
  'cfo_grants_active', (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'cfo' AND ur.revoked_at IS NULL))::text;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|recon ' || string_agg(s->>'side' || ' unexplained=' || COALESCE(s->>'unexplained_base', 'null') || ' agrees=' || COALESCE(s->>'agrees', 'null'), ' · ')
  FROM jsonb_array_elements((SELECT list_ledger_reconciliation())->'sides') s;
ROLLBACK;
