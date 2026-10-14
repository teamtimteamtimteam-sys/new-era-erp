-- MES-6a-2 close-out (step 1 of the MES-6a-2 close-out + MES-6b Step 0 brief, 2026-10-14) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables and the catalog. Nothing written.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';

-- window use: anything of this cut's kinds since the migration committed (2026-10-10 12:45:10 CST)
SELECT 'W|substances=' || (SELECT string_agg(code || ':' || role, ',' ORDER BY sort_order) FROM substances);
SELECT 'W|indicator definitions=' || (SELECT string_agg(code || (CASE WHEN is_active THEN '' ELSE '(inactive)' END), ',' ORDER BY code) FROM assay_indicators)
    || '|indicator values=' || (SELECT count(*) FROM assay_result_indicators);
SELECT 'W|penalty element rows=' || (SELECT count(*) FROM contract_penalty_elements)
    || '|contracts (not deleted)=' || (SELECT count(*) FROM contracts WHERE deleted_at IS NULL)
    || '|contracts (all)=' || (SELECT count(*) FROM contracts);
SELECT 'W|F/Cl content rows: assay=' || (SELECT count(*) FROM assay_result_metals WHERE metal IN ('f', 'cl'))
    || '|inbound=' || (SELECT count(*) FROM inbound_batch_metals WHERE metal IN ('f', 'cl'))
    || '|output=' || (SELECT count(*) FROM output_batch_metals WHERE metal IN ('f', 'cl'));
SELECT 'W|assays=' || (SELECT count(*) FROM assay_results)
    || '|assays created since window=' || (SELECT count(*) FROM assay_results WHERE created_at >= '2026-10-10 12:45:10+08')
    || '|substances created/changed since window (change_log)=' || (SELECT count(*) FROM change_log WHERE table_name = 'substances' AND occurred_at >= '2026-10-10 12:45:11+08')
    || '|metal_prices created since window=' || (SELECT count(*) FROM metal_prices WHERE created_at >= '2026-10-10 12:45:10+08');

-- ids for the deployed-app probe (read only: which ids)
SELECT 'D|inbound batch|' || id || '|' || code FROM inbound_batches WHERE deleted_at IS NULL ORDER BY code DESC LIMIT 1;
SELECT 'D|output batch|' || id || '|' || code FROM output_batches WHERE deleted_at IS NULL ORDER BY code DESC LIMIT 1;
SELECT 'D|contract|' || id || '|' || code || '|' || status || '|' || kind FROM contracts WHERE deleted_at IS NULL ORDER BY code DESC LIMIT 3;

-- standing state
SELECT 'S|approvals_on=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '?') || '|l2=' || COALESCE(approval_level2_role_code, '?') || '|threshold=' || COALESCE(approval_threshold_base::text, '?') FROM finance_settings;
SELECT 'S|accounts=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'S|throwaway accounts=' || count(*) FROM auth.users WHERE email LIKE '%@test.local';
SELECT 'S|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL');
SELECT 'S|catalogue=' || (SELECT count(*) FROM permissions) || '|admin=' || (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin');
SELECT 'S|codes per live role|' || ro.code || '=' || count(rp.*)
  FROM roles ro LEFT JOIN role_permissions rp ON rp.role_id = ro.id
 WHERE EXISTS (SELECT 1 FROM user_roles ur JOIN auth.users u ON u.id = ur.user_id
                WHERE ur.role_id = ro.id AND ur.revoked_at IS NULL AND u.email NOT LIKE '%@test.local')
 GROUP BY ro.code ORDER BY ro.code;
SELECT 'S|document_types=' || (SELECT count(*) FROM document_types);
ROLLBACK;
