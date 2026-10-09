-- MES-6a Step 0 — live readings, read-only (BEGIN READ ONLY … ROLLBACK). Identity: postgres (rolbypassrls = true), base tables and the catalog.
-- Nothing written. Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-6a/live-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';

-- assays
SELECT 'ASY|total=' || count(*) || '|live=' || count(*) FILTER (WHERE deleted_at IS NULL)
    || '|on inbound=' || count(*) FILTER (WHERE inbound_batch_id IS NOT NULL AND deleted_at IS NULL)
    || '|on output=' || count(*) FILTER (WHERE output_batch_id IS NOT NULL AND deleted_at IS NULL)
    || '|applied=' || count(*) FILTER (WHERE applied_at IS NOT NULL AND deleted_at IS NULL)
    || '|superseded=' || count(*) FILTER (WHERE superseded_by IS NOT NULL)
    || '|sample_ref set=' || count(*) FILTER (WHERE sample_ref IS NOT NULL AND btrim(sample_ref) <> '')
    || '|lab set=' || count(*) FILTER (WHERE lab_name IS NOT NULL)
    || '|moisture set=' || count(*) FILTER (WHERE moisture_pct IS NOT NULL)
  FROM assay_results;
SELECT 'ASY|party|' || result_party || '|' || count(*) FROM assay_results WHERE deleted_at IS NULL GROUP BY result_party ORDER BY 1;
SELECT 'ASY|basis|' || COALESCE(weight_basis, 'NULL') || '|' || count(*) FROM assay_results WHERE deleted_at IS NULL GROUP BY weight_basis ORDER BY 1;
SELECT 'ASY|metal rows=' || count(*) || '|distinct metals=' || count(DISTINCT metal) FROM assay_result_metals;
SELECT 'ASY|batches with more than one live assay=' || count(*) FROM (
    SELECT COALESCE(inbound_batch_id, output_batch_id) b FROM assay_results WHERE deleted_at IS NULL GROUP BY 1 HAVING count(*) > 1) x;

-- laboratories, substances
SELECT 'LAB|rows=' || count(*) || '|active=' || count(*) FILTER (WHERE is_active) || '|codes=' || COALESCE(string_agg(code, ',' ORDER BY code), '') FROM laboratories;
SELECT 'SUB|rows=' || count(*) || '|codes=' || string_agg(code || CASE WHEN is_active THEN '' ELSE '(inactive)' END, ',' ORDER BY sort_order, code) FROM substances;
SELECT 'SUB|fk columns=' || count(*) || '|' || string_agg(c.conrelid::regclass::text || '.' || a.attname, ',' ORDER BY 1)
  FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
 WHERE c.contype = 'f' AND c.confrelid = 'public.substances'::regclass;

-- contracts and their quality terms
SELECT 'CTR|contracts=' || count(*) || '|by kind=' || COALESCE((SELECT string_agg(kind || ':' || n, ',') FROM (SELECT kind, count(*) n FROM contracts GROUP BY kind) k), '')
    || '|by status=' || COALESCE((SELECT string_agg(status || ':' || n, ',') FROM (SELECT status, count(*) n FROM contracts GROUP BY status) s), '') FROM contracts;
SELECT 'CTR|settlement terms=' || count(*) || '|splitting limit set=' || count(*) FILTER (WHERE splitting_limit_pct IS NOT NULL)
    || '|retention required=' || count(*) FILTER (WHERE sample_retention_required) || '|retention days set=' || count(*) FILTER (WHERE sample_retention_days IS NOT NULL)
  FROM contract_settlement_terms;
SELECT 'CTR|penalty elements=' || (SELECT count(*) FROM contract_penalty_elements) || '|grade specs=' || (SELECT count(*) FROM contract_grade_specs)
    || '|refining charges=' || (SELECT count(*) FROM contract_refining_charges);
SELECT 'CTR|sales settlements=' || count(*) FROM sales_settlements;

-- inline quality: the data class and any device of that kind
SELECT 'ING|class inline_quality|active=' || is_active || '|transform=' || COALESCE(transform_function, 'NULL') || '|manual code=' || COALESCE(manual_entry_code, 'NULL')
  FROM ingest_data_classes WHERE code = 'inline_quality';
SELECT 'ING|classes with no transform=' || string_agg(code, ',' ORDER BY sort_order) FROM ingest_data_classes WHERE transform_function IS NULL;
SELECT 'ING|devices by kind=' || COALESCE(string_agg(kind || ':' || n, ',' ORDER BY kind), '') FROM (SELECT kind, count(*) n FROM devices GROUP BY kind) d;
SELECT 'ING|inbox rows=' || count(*) || '|awaiting_transform=' || count(*) FILTER (WHERE status = 'awaiting_transform') FROM ingest_inbox;

-- F3: expenses and their reversals
SELECT 'EXP|total=' || count(*) || '|posted=' || count(*) FILTER (WHERE status = 'posted') || '|reversed=' || count(*) FILTER (WHERE status = 'reversed')
    || '|mirrors (reversed_by_expense set)=' || count(*) FILTER (WHERE reversed_by_expense IS NOT NULL) FROM expenses;
SELECT 'EXP|electricity allocation reversals=' || count(*) FROM electricity_allocation_reversals;

-- registries the cut would touch
SELECT 'REG|document_types=' || count(*) || '|SMP=' || count(*) FILTER (WHERE prefix = 'SMP') || '|ASY=' || count(*) FILTER (WHERE prefix = 'ASY') FROM document_types;
SELECT 'REG|permissions=' || count(*) || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%') || '|quality codes=' || count(*) FILTER (WHERE code LIKE '%quality%') FROM permissions;
SELECT 'REG|change_log coverage=' || change_log_coverage_gaps()::text;
SELECT 'REG|holders|' || rp.permission_code || '|' || string_agg(DISTINCT r.code, ',' ORDER BY r.code)
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code IN ('action.apply_assay', 'module.inbound.edit', 'module.output.edit', 'module.finance.edit', 'action.contract_terms',
                              'action.price_receipts', 'module.materials.edit', 'action.confirm_capture')
   AND EXISTS (SELECT 1 FROM user_roles ur JOIN auth.users u ON u.id = ur.user_id WHERE ur.role_id = r.id AND ur.revoked_at IS NULL AND u.email NOT LIKE '%@test.local')
 GROUP BY rp.permission_code ORDER BY rp.permission_code;

-- standing state
SELECT 'S|approvals_on=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '?') || '|l2=' || COALESCE(approval_level2_role_code, '?') || '|threshold=' || COALESCE(approval_threshold_base::text, '?') FROM finance_settings;
SELECT 'S|accounts=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'S|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL');
ROLLBACK;
