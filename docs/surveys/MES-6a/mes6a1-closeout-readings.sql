-- MES-6a-1 close-out (step 1 of the MES-6a-1 close-out + MES-6a-2 brief, 2026-10-10) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables and the catalog. Nothing written.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';

-- window use: anything of the new kinds since the migration committed (2026-10-09 22:33:44 CST)
SELECT 'W|samples=' || (SELECT count(*) FROM samples)
    || '|sample_events=' || (SELECT count(*) FROM sample_events)
    || '|disputes=' || (SELECT count(*) FROM assay_disputes)
    || '|V16=' || COALESCE((SELECT internal_retention_days::text FROM quality_settings LIMIT 1), 'NULL')
    || '|assays with sample=' || (SELECT count(*) FROM assay_results WHERE sample_id IS NOT NULL)
    || '|labs linked to a supplier=' || (SELECT count(*) FROM laboratories WHERE supplier_id IS NOT NULL)
    || '|V14 set=' || (SELECT count(*) FROM contract_settlement_terms WHERE arbitration_fee_rule IS NOT NULL)
    || '|expenses reversed=' || (SELECT count(*) FROM expenses WHERE status = 'reversed')
    || '|reversal reasons=' || (SELECT count(*) FROM expenses WHERE reversal_reason IS NOT NULL)
    || '|expenses created since window=' || (SELECT count(*) FROM expenses WHERE created_at >= '2026-10-09 22:33:44+08')
    || '|assays created since window=' || (SELECT count(*) FROM assay_results WHERE created_at >= '2026-10-09 22:33:44+08');

-- b · the nine quality grants, role by role (every role, held or not)
SELECT 'B|quality grant|' || r.code || '|' || string_agg(rp.permission_code, ',' ORDER BY rp.permission_code)
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code LIKE 'module.quality.%'
 GROUP BY r.code ORDER BY r.code;
SELECT 'B|quality grants total=' || count(*) FROM role_permissions WHERE permission_code LIKE 'module.quality.%';
SELECT 'B|quality codes in catalogue=' || string_agg(code, ',' ORDER BY code) FROM permissions WHERE code LIKE 'module.quality.%';
SELECT 'B|action.apply_assay declares=' || array_to_string(requires_view_any, ',') FROM permissions WHERE code = 'action.apply_assay';
-- action-implies-view, for every role that has a live (real) holder — the fixture 257 FCHECK predicate, read on live
SELECT 'B|action-implies-view violations (roles with a real holder)=' || COALESCE(string_agg(ro.code || '->' || rp.permission_code, ', '), 'none')
  FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
 WHERE p.requires_view_any IS NOT NULL
   AND EXISTS (SELECT 1 FROM user_roles ur JOIN auth.users u ON u.id = ur.user_id
                WHERE ur.role_id = ro.id AND ur.revoked_at IS NULL AND u.email NOT LIKE '%@test.local')
   AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
SELECT 'B|action-implies-view violations (every role)=' || COALESCE(string_agg(ro.code || '->' || rp.permission_code, ', '), 'none')
  FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
 WHERE p.requires_view_any IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
SELECT 'B|pairs checked (roles with a real holder)=' || count(*)
  FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
 WHERE p.requires_view_any IS NOT NULL
   AND EXISTS (SELECT 1 FROM user_roles ur JOIN auth.users u ON u.id = ur.user_id
                WHERE ur.role_id = ro.id AND ur.revoked_at IS NULL AND u.email NOT LIKE '%@test.local');
SELECT 'B|codes per live role|' || ro.code || '=' || count(rp.*)
  FROM roles ro LEFT JOIN role_permissions rp ON rp.role_id = ro.id
 WHERE EXISTS (SELECT 1 FROM user_roles ur JOIN auth.users u ON u.id = ur.user_id
                WHERE ur.role_id = ro.id AND ur.revoked_at IS NULL AND u.email NOT LIKE '%@test.local')
 GROUP BY ro.code ORDER BY ro.code;
SELECT 'B|catalogue=' || (SELECT count(*) FROM permissions) || '|admin=' || (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin');

-- c · registries, arms
SELECT 'C|document_types SMP|' || key || '|' || prefix || '|' || table_name || '|' || numbering || '|' || route FROM document_types WHERE prefix = 'SMP';
SELECT 'C|document_types rows=' || count(*) FROM document_types;
SELECT 'C|pending_values arms V16=' || (pg_get_viewdef('public.pending_values'::regclass) LIKE '%''V16''::text%')
    || '|V14=' || (pg_get_viewdef('public.pending_values'::regclass) LIKE '%''V14''::text%');
SELECT 'C|operations_now arms sample_retention_due=' || (pg_get_viewdef('public.operations_now'::regclass) LIKE '%''sample_retention_due''::text%')
    || '|assay_dispute_open=' || (pg_get_viewdef('public.operations_now'::regclass) LIKE '%''assay_dispute_open''::text%')
    || '|assay_results_disagree=' || (pg_get_viewdef('public.operations_now'::regclass) LIKE '%''assay_results_disagree''::text%');
SELECT 'C|change_log coverage=' || change_log_coverage_gaps()::text;
SELECT 'C|trail subjects sample=' || (pg_get_functiondef('public.trail_subjects'::regproc) LIKE '%(''sample'',%')
    || '|assay_dispute=' || (pg_get_functiondef('public.trail_subjects'::regproc) LIKE '%(''assay_dispute'',%')
    || '|quality_settings=' || (pg_get_functiondef('public.trail_subjects'::regproc) LIKE '%(''quality_settings'',%');

-- d · a real expense the reversal dialog can be opened on (read only: which ids, which status) — the probe never confirms
SELECT 'D|posted expense for the dialog|' || id || '|' || code || '|' || status FROM expenses
 WHERE status = 'posted' ORDER BY code DESC LIMIT 1;
SELECT 'D|batch for the new-sample page|' || id || '|' || code FROM inbound_batches WHERE deleted_at IS NULL ORDER BY code DESC LIMIT 1;

-- standing state
SELECT 'S|approvals_on=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '?') || '|l2=' || COALESCE(approval_level2_role_code, '?') || '|threshold=' || COALESCE(approval_threshold_base::text, '?') FROM finance_settings;
SELECT 'S|accounts=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'S|throwaway accounts=' || count(*) FROM auth.users WHERE email LIKE '%@test.local';
SELECT 'S|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL');
ROLLBACK;
