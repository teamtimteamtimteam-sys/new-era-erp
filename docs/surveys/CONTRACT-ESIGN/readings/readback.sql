-- CONTRACT-ESIGN 读回(每一次线上证明 / 冒烟之后):以 postgres(rolbypassrls)只数,基表 ⇒ 真行数;对账那一句以 tim@(cfo)身份,整笔回滚
SELECT 'PROOF|' || json_build_object(
  'users', (SELECT count(*) FROM auth.users),
  'enabled', (SELECT count(*) FROM auth.users WHERE banned_until IS NULL OR banned_until < now()),
  'throwaway_users', (SELECT count(*) FROM auth.users WHERE email ~ '^(cesprobe|gl2probe|survey|smoke)-'),
  'throwaway_roles', (SELECT count(*) FROM roles WHERE code LIKE 'probe-%'),
  'orphan_grants', (SELECT count(*) FROM user_roles ur WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ur.user_id)),
  'throwaway_employees', (SELECT count(*) FROM employees WHERE code LIKE 'ZZ-PROBE-CES%'),
  'throwaway_suppliers', (SELECT count(*) FROM suppliers WHERE legal_name LIKE 'ZZ-PROBE cesprobe%'),
  'contracts', (SELECT count(*) FROM contracts),
  'contract_files', (SELECT count(*) FROM contract_files), 'contract_signatories', (SELECT count(*) FROM contract_signatories),
  'signature_specimens', (SELECT count(*) FROM signature_specimens), 'company_stamps', (SELECT count(*) FROM company_stamps),
  'objects_contract_files', (SELECT count(*) FROM storage.objects WHERE bucket_id = 'contract-files'),
  'objects_signing_assets', (SELECT count(*) FROM storage.objects WHERE bucket_id = 'signing-assets'),
  'role_codes_held', (SELECT string_agg(DISTINCT r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.revoked_at IS NULL),
  'cfo_grants_active', (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'cfo' AND ur.revoked_at IS NULL),
  'roles', (SELECT count(*) FROM roles),
  'approvals', (SELECT approvals_enabled FROM finance_settings LIMIT 1),
  'chain', (SELECT approval_level1_role_code || '/' || approval_level2_role_code || '/' || approval_threshold_base::int FROM finance_settings LIMIT 1),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings LIMIT 1),
  'cods', (SELECT count(*) FROM cod_issues))::text;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|recon ' || string_agg(s->>'side' || ' unexplained=' || COALESCE(s->>'unexplained_base', 'null') || ' agrees=' || COALESCE(s->>'agrees', 'null'), ' · ')
  FROM jsonb_array_elements((SELECT list_ledger_reconciliation())->'sides') s;
ROLLBACK;
