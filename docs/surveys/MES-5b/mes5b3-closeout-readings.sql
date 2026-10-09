-- MES-5b-3 close-out (step 1 of the MES-5b-3 close-out + MES-6a Step 0 brief, 2026-10-09) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables and the catalog. Nothing written.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';

-- window use: anything of the new kinds since the migration committed (2026-10-09 17:21:45 CST)
SELECT 'W|plans=' || (SELECT count(*) FROM blending_plans)
    || '|targets=' || (SELECT count(*) FROM blending_plan_targets)
    || '|lines=' || (SELECT count(*) FROM blending_plan_lines)
    || '|blending runs=' || (SELECT count(*) FROM processing_runs WHERE operation_type_code = 'blending')
    || '|runs created since window=' || (SELECT count(*) FROM processing_runs WHERE created_at >= '2026-10-09 17:21:45+08');

-- b · the live catalogue: trail subject + members, BLD row, change-log exclusions
SELECT 'B|trail subject blending_plan on live=' || (pg_get_functiondef('public.trail_subjects'::regproc) LIKE '%(''blending_plan'',          ARRAY[''module.processing.view''], ''blending_plans''%')
    || '|members targets=' || (pg_get_functiondef('public.trail_subject_members'::regproc) LIKE '%(''blending_plan'',      1, ''blending_plan_targets''%')
    || '|members lines=' || (pg_get_functiondef('public.trail_subject_members'::regproc) LIKE '%(''blending_plan'',      2, ''blending_plan_lines''%');
SELECT 'B|document_types BLD|' || key || '|' || prefix || '|' || table_name || '|' || numbering || '|' || route FROM document_types WHERE prefix = 'BLD';
SELECT 'B|document_types rows=' || count(*) FROM document_types;
SELECT 'B|change_log coverage=' || change_log_coverage_gaps()::text;

-- d · the operation and the admin role
SELECT 'D|operation blending|active=' || is_active || '|started_from_run_page=' || started_from_run_page || '|tolerance=' || COALESCE(balance_tolerance_pct::text, 'NULL')
  FROM operation_types WHERE code = 'blending';
SELECT 'D|operations offered on the ordinary new-run form=' || string_agg(code, ',' ORDER BY code) FROM operation_types WHERE is_active AND NOT started_from_run_page;
SELECT 'D|catalogue=' || (SELECT count(*) FROM permissions) || '|admin=' || (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin');
SELECT 'D|holders|' || rp.permission_code || '|' || string_agg(DISTINCT r.code, ',' ORDER BY r.code)
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code IN ('action.wo_create', 'action.wo_release', 'action.processing_commit', 'module.processing.view')
   AND EXISTS (SELECT 1 FROM user_roles ur JOIN auth.users u ON u.id = ur.user_id WHERE ur.role_id = r.id AND ur.revoked_at IS NULL AND u.email NOT LIKE '%@test.local')
 GROUP BY rp.permission_code ORDER BY rp.permission_code;
SELECT 'D|saleable powder batches|inbound=' || (SELECT count(*) FROM inbound_batches b JOIN materials m ON m.id = b.material_id
                                                 WHERE b.deleted_at IS NULL AND m.form_code IN ('black_mass', 'cathode_powder', 'anode_powder') AND b.remaining_qty > 0)
    || '|output=' || (SELECT count(*) FROM output_batches b JOIN materials m ON m.id = b.material_id
                       WHERE b.deleted_at IS NULL AND m.form_code IN ('black_mass', 'cathode_powder', 'anode_powder') AND b.remaining_qty > 0);

-- standing state
SELECT 'S|approvals_on=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '?') || '|l2=' || COALESCE(approval_level2_role_code, '?') || '|threshold=' || COALESCE(approval_threshold_base::text, '?') FROM finance_settings;
SELECT 'S|accounts=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'S|throwaway accounts=' || count(*) FROM auth.users WHERE email LIKE '%@test.local';
SELECT 'S|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL');
ROLLBACK;
