-- MES-6b Step 0 (2026-10-15) — read-only, BEGIN READ ONLY … ROLLBACK. Identity: postgres (rolbypassrls = true), base tables and the catalog.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- batches, assays, chemistry certainty (N38)
SELECT 'B|inbound batches (not deleted)=' || (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NULL)
    || '|with chemistry_certainty_code=' || (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NULL AND chemistry_certainty_code IS NOT NULL)
    || '|output batches (not deleted)=' || (SELECT count(*) FROM output_batches WHERE deleted_at IS NULL)
    || '|output batches with metal content=' || (SELECT count(DISTINCT output_batch_id) FROM output_batch_metals)
    || '|output content rows by source=' || COALESCE((SELECT string_agg(content_source || ':' || n, ',') FROM (SELECT content_source, count(*) n FROM output_batch_metals GROUP BY 1) x), 'none');
SELECT 'A|assays=' || (SELECT count(*) FROM assay_results WHERE deleted_at IS NULL)
    || '|on output batches=' || (SELECT count(*) FROM assay_results WHERE deleted_at IS NULL AND output_batch_id IS NOT NULL)
    || '|with moisture=' || (SELECT count(*) FROM assay_results WHERE moisture_pct IS NOT NULL)
    || '|indicator values=' || (SELECT count(*) FROM assay_result_indicators)
    || '|samples=' || (SELECT count(*) FROM samples) || '|disputes=' || (SELECT count(*) FROM assay_disputes);
-- holds and quarantine today
SELECT 'H|on_hold movements=' || (SELECT count(*) FROM inventory_movements WHERE stock_status = 'on_hold')
    || '|committed movements=' || (SELECT count(*) FROM inventory_movements WHERE stock_status = 'committed')
    || '|reservations=' || (SELECT count(*) FROM sales_order_reservations)
    || '|quarantine locations=' || (SELECT count(*) FROM storage_locations WHERE is_quarantine)
    || '|open warehouse requests=' || (SELECT count(*) FROM warehouse_requests WHERE status = 'submitted');
-- contracts, sales, certificates
SELECT 'C|contracts=' || (SELECT count(*) FROM contracts) || '|grade specs=' || (SELECT count(*) FROM contract_grade_specs)
    || '|sales orders=' || (SELECT count(*) FROM sales_orders) || '|sales settlements=' || (SELECT count(*) FROM sales_settlements)
    || '|CODs=' || (SELECT count(*) FROM certificates_of_destruction) || '|COD issued=' || (SELECT count(*) FROM certificates_of_destruction WHERE status = 'issued')
    || '|traceability report issues=' || (SELECT count(*) FROM traceability_report_issues);
-- registries, arms, catalogue
SELECT 'R|document_types=' || (SELECT count(*) FROM document_types)
    || '|NCR prefix=' || (SELECT count(*) FROM document_types WHERE prefix IN ('NCR', 'COA'))
    || '|tables in public=' || (SELECT count(*) FROM pg_tables WHERE schemaname = 'public')
    || '|catalogue=' || (SELECT count(*) FROM permissions) || '|ncr/coa codes=' || (SELECT count(*) FROM permissions WHERE code IN ('action.ncr_decide', 'action.issue_coa'));
SELECT 'R|operations_now arms=' || (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), '''([a-z_]+)''::text AS item_type', 'g'))
    || '|pending_values arms=' || (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), '''(V[0-9]+)''::text', 'g'));
-- standing state
SELECT 'S|approvals_on=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '?') || '|l2=' || COALESCE(approval_level2_role_code, '?') || '|threshold=' || COALESCE(approval_threshold_base::text, '?') FROM finance_settings;
SELECT 'S|accounts=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'S|throwaway accounts=' || count(*) FROM auth.users WHERE email LIKE '%@test.local';
SELECT 'S|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL');
SELECT 'S|admin=' || (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin');
ROLLBACK;
