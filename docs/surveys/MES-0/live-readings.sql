-- MES-0 live readings (2026-10-05, 19:16–19:45 CST). Every block BEGIN READ ONLY … ROLLBACK.
-- Run as postgres (rolbypassrls = true) over psql to the pooler; base tables unless a view is named.

BEGIN READ ONLY;
\pset pager off
SELECT 'substances' t, string_agg(code||'('||coalesce(symbol,'')||','||is_active||')', ' ' ORDER BY sort_order) FROM substances;
SELECT 'material_forms', count(*), string_agg(code||':'||name_en||(CASE WHEN is_active THEN '' ELSE '[inactive]' END), ' | ' ORDER BY sort_order) FROM material_forms;
SELECT 'material_kinds', count(*), string_agg(code, ' ' ORDER BY sort_order) FROM material_kinds;
SELECT 'operation_kinds', string_agg(code||'(in:'||consumes_input||',out:'||produces_outputs||')', ' ' ORDER BY sort_order) FROM operation_kinds;
SELECT 'operation_types', string_agg(code||'/'||kind_code||'->'||coalesce(resulting_safety_state_code,'-'), ' ' ORDER BY sort_order) FROM operation_types;
SELECT 'loss_categories', string_agg(code||'('||metal_fate||','||is_true_loss||')', ' ' ORDER BY sort_order) FROM loss_categories;
SELECT 'inbound_safety_states', string_agg(code||'(fed:'||may_be_fed||')', ' ' ORDER BY sort_order) FROM inbound_safety_states;
SELECT 'deep_discharge_judgements', string_agg(code, ' ' ORDER BY sort_order) FROM deep_discharge_judgements;
SELECT 'battery_chemistries', string_agg(code, ' ' ORDER BY sort_order) FROM battery_chemistries;
SELECT 'laboratories', string_agg(code, ' ' ORDER BY sort_order) FROM laboratories;
SELECT 'certificate_types', string_agg(code||'('||disposition||',lead:'||coalesce(warn_lead_days::text,'null')||')', ' ' ORDER BY sort_order) FROM certificate_types;
SELECT 'company_compliance', count(*), string_agg(cert_type_code||':'||coalesce(approved_storage_limit_tonnes::text,'null')||':'||coalesce(status,''), ' ') FROM company_compliance WHERE deleted_at IS NULL;
SELECT 'waste_classifications', string_agg(code||'(ctrl:'||is_controlled||')', ' ' ORDER BY sort_order) FROM waste_classifications;
SELECT 'output_batch_purposes', string_agg(code, ' ' ORDER BY sort_order) FROM output_batch_purposes;
SELECT 'output_batch_states', string_agg(code, ' ' ORDER BY sort_order) FROM output_batch_states;
SELECT 'storage_locations', count(*), string_agg(code||'@'||coalesce(zone,''), ' ' ORDER BY code) FROM storage_locations;
SELECT 'location_allowed', string_agg(DISTINCT classification_code, ' ') FROM storage_location_allowed_classes;
SELECT 'document_types', count(*), string_agg(prefix||'='||key, ' ' ORDER BY prefix) FROM document_types;
SELECT 'processing_settings', row_to_json(p)::text FROM processing_settings p;
SELECT 'receiving_settings', row_to_json(p)::text FROM receiving_settings p;
SELECT 'finance_settings', approvals_enabled, approval_level1_role_code, approval_level2_role_code, approval_threshold_base FROM finance_settings;
SELECT 'roles', string_agg(code||(CASE WHEN is_active THEN '' ELSE '[off]' END), ' ' ORDER BY sort_order) FROM roles WHERE deleted_at IS NULL;
SELECT u.email, string_agg(r.code, ',') FROM auth.users u LEFT JOIN user_roles ur ON ur.user_id=u.id AND ur.revoked_at IS NULL LEFT JOIN roles r ON r.id=ur.role_id GROUP BY u.email ORDER BY 1;
SELECT 'permissions', count(*), count(*) FILTER (WHERE code LIKE 'module.%') mod, count(*) FILTER (WHERE code LIKE 'action.%') act, count(*) FILTER (WHERE code LIKE 'data.%') dat FROM permissions;
SELECT 'public_tables', count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r';
SELECT 'change_logged_tables', count(DISTINCT event_object_table) FROM information_schema.triggers WHERE trigger_schema='public' AND action_statement ILIKE '%change_log%';
SELECT 'counts', (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NULL) ib, (SELECT count(*) FROM output_batches WHERE deleted_at IS NULL) ob, (SELECT count(*) FROM processing_runs WHERE deleted_at IS NULL) runs, (SELECT count(*) FROM processing_runs WHERE deleted_at IS NULL AND equipment_id IS NOT NULL) runs_with_eq, (SELECT count(*) FROM fixed_assets) fa, (SELECT count(*) FROM equipment_downtime) dt, (SELECT count(*) FROM equipment_maintenance) em, (SELECT count(*) FROM assay_results WHERE deleted_at IS NULL) assays, (SELECT count(*) FROM shipments) shp, (SELECT count(*) FROM suppliers) sup, (SELECT count(*) FROM contracts) ctr, (SELECT count(*) FROM contract_penalty_elements) pen, (SELECT count(*) FROM contract_settlement_terms) cst, (SELECT count(*) FROM work_orders) wo;
SELECT 'cst', splitting_limit_pct, sample_retention_required, sample_retention_days, settling_party FROM contract_settlement_terms;
SELECT 'penalty_subst', string_agg(DISTINCT substance, ' ') FROM contract_penalty_elements;
ROLLBACK;
BEGIN READ ONLY;
\pset pager off
SELECT DISTINCT trigger_name FROM information_schema.triggers WHERE trigger_schema='public' AND action_statement ILIKE '%change_log%' LIMIT 20;
SELECT 'clog_fn_tables', count(DISTINCT event_object_table) FROM information_schema.triggers WHERE trigger_schema='public' AND action_statement ILIKE '%change_log_capture%';
SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relname NOT IN (SELECT DISTINCT event_object_table FROM information_schema.triggers WHERE trigger_schema='public' AND action_statement ILIKE '%change_log%') ORDER BY 1;
ROLLBACK;
BEGIN READ ONLY;
\pset pager off
SELECT code, name_en, left(coalesce(notes,''),160) FROM operation_types ORDER BY sort_order;
SELECT code, is_system, is_active FROM roles WHERE deleted_at IS NULL ORDER BY sort_order;
SELECT table_name, column_name, data_type, numeric_precision, numeric_scale FROM information_schema.columns WHERE table_schema='public' AND ((table_name='assay_result_metals' AND column_name='content_pct') OR (table_name='inbound_batch_metals' AND column_name LIKE 'content%'));
-- (shifts has starts_at/ends_at, not start_time; this line errored at run time and the rest of this block was re-run as the next block)
SELECT operation_type_code, string_agg(form_code, ',') FROM operation_type_output_forms GROUP BY 1;
SELECT operation_type_code, string_agg(form_code, ',') FROM operation_type_input_forms GROUP BY 1;
SELECT count(*) FILTER (WHERE has_function_privilege('anon', p.oid, 'EXECUTE')) anon_exec, count(*) total FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public';
SELECT count(*) AS policies_using_true FROM pg_policies WHERE schemaname='public' AND qual='true' AND 'authenticated' = ANY(roles);
SELECT count(*) AS authenticated_policies_total FROM pg_policies WHERE schemaname='public';
SELECT extname FROM pg_extension ORDER BY 1;
ROLLBACK;
BEGIN READ ONLY;
\pset pager off
SELECT string_agg(column_name, ',') FROM information_schema.columns WHERE table_schema='public' AND table_name='shifts';
SELECT * FROM shifts;
SELECT operation_type_code, string_agg(form_code, ',') FROM operation_type_output_forms GROUP BY 1;
SELECT operation_type_code, string_agg(form_code, ',') FROM operation_type_input_forms GROUP BY 1;
SELECT count(*) FILTER (WHERE has_function_privilege('anon', p.oid, 'EXECUTE')) anon_exec, count(*) total FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public';
SELECT count(*) AS policies_qual_true_for_authenticated FROM pg_policies WHERE schemaname='public' AND qual='true' AND 'authenticated' = ANY(roles) AND cmd IN ('SELECT','ALL');
SELECT count(*) AS policies_total FROM pg_policies WHERE schemaname='public';
SELECT string_agg(extname, ' ' ORDER BY extname) FROM pg_extension;
ROLLBACK;
BEGIN READ ONLY;
\pset pager off
SELECT count(*) all_runs, count(*) FILTER (WHERE deleted_at IS NULL) undeleted, count(*) FILTER (WHERE equipment_id IS NOT NULL) with_machine FROM processing_runs;
DO $$ DECLARE r record; n bigint; tot bigint := 0; BEGIN
  FOR r IN SELECT DISTINCT table_name FROM document_types LOOP
    EXECUTE format('SELECT count(*) FROM public.%I', r.table_name) INTO n; tot := tot + n; END LOOP;
  RAISE NOTICE 'rows across % document tables: %', (SELECT count(DISTINCT table_name) FROM document_types), tot; END $$;
SELECT count(*) AS change_log_rows FROM change_log;
SELECT count(*) AS movements FROM inventory_movements;
ROLLBACK;
