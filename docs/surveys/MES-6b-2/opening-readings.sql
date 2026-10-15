-- MES-6b-1 close-out + MES-6b-2 opening reading (2026-10-15) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r') and the catalog, so counts are real row counts, not a permission answer.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-6b-2/opening-readings.sql
-- The reconciliation is read separately in tim@'s session: db/scripts/2026-10-05-at1d3-live-recon.sql.
-- Re-run unchanged as the "after" reading (the W| lines then cover the MES-6b-2 window as well).
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';

-- W · what happened on live since the MES-6b-1 migration committed (2026-10-15 16:50:30 CST = 08:50:30 UTC)
SELECT 'W|ncrs created since=' || count(*) FILTER (WHERE opened_at >= '2026-10-15 08:50:30+00') || '|ncrs all=' || count(*) FROM nonconformance_reports;
SELECT 'W|quality limits=' || (SELECT count(*) FROM contract_quality_limits) || '|judgements=' || (SELECT count(*) FROM quality_limit_judgements)
    || '|basis set=' || (SELECT count(*) FROM contract_settlement_terms WHERE quality_limit_basis IS NOT NULL);
SELECT 'W|contracts all=' || count(*) || '|created since=' || count(*) FILTER (WHERE created_at >= '2026-10-15 08:50:30+00') FROM contracts;
SELECT 'W|assays created since=' || count(*) FILTER (WHERE created_at >= '2026-10-15 08:50:30+00') || '|all=' || count(*) FROM assay_results;
SELECT 'W|reservations created since=' || count(*) FILTER (WHERE created_at >= '2026-10-15 08:50:30+00') FROM sales_order_reservations;
SELECT 'W|movements since=' || count(*) FILTER (WHERE created_at >= '2026-10-15 08:50:30+00') FROM inventory_movements;
SELECT 'W|change_log since=' || count(*) || '|' || COALESCE((SELECT string_agg(t || ':' || n, ',' ORDER BY t) FROM (SELECT table_name || '/' || op t, count(*) n FROM change_log WHERE occurred_at >= '2026-10-15 08:50:30+00' GROUP BY 1) y), '')
  FROM change_log WHERE occurred_at >= '2026-10-15 08:50:30+00';

-- 1 · output batches, assays, lineage, chemistry certainty (N38's inputs)
SELECT 'OUTPUT|not deleted=' || count(*) FILTER (WHERE deleted_at IS NULL) || '|all=' || count(*) FROM output_batches;
SELECT 'INBOUND|not deleted=' || count(*) FILTER (WHERE deleted_at IS NULL) || '|with certainty=' || count(*) FILTER (WHERE deleted_at IS NULL AND chemistry_certainty_code IS NOT NULL)
  FROM inbound_batches;
SELECT 'CERTAINTY|' || c || '=' || n FROM (SELECT COALESCE(chemistry_certainty_code, 'NULL') c, count(*) n FROM inbound_batches WHERE deleted_at IS NULL GROUP BY 1) x ORDER BY c;
SELECT 'ASSAYS|all=' || count(*) || '|live=' || count(*) FILTER (WHERE deleted_at IS NULL)
    || '|inbound=' || count(*) FILTER (WHERE inbound_batch_id IS NOT NULL) || '|output=' || count(*) FILTER (WHERE output_batch_id IS NOT NULL)
    || '|final=' || count(*) FILTER (WHERE is_final) FROM assay_results;
SELECT 'DISPUTES|all=' || count(*) || '|open=' || count(*) FILTER (WHERE status = 'open') FROM assay_disputes;
SELECT 'RESERVATIONS|all=' || count(*) || '|open=' || count(*) FILTER (WHERE released_at IS NULL AND consumed_at IS NULL) FROM sales_order_reservations;
SELECT 'SALES_ORDERS|' || count(*) FROM sales_orders;

-- 2 · certificates: COD (the precedent) and the CoA registry state
SELECT 'COD|all=' || count(*) || '|issued=' || count(*) FILTER (WHERE status = 'issued') || '|void=' || count(*) FILTER (WHERE status = 'void')
  FROM certificates_of_destruction;
SELECT 'COD_ISSUES|' || count(*) FROM cod_issues;
SELECT 'COA|table=' || (to_regclass('public.certificates_of_analysis') IS NOT NULL)
    || '|issues table=' || (to_regclass('public.coa_issues') IS NOT NULL)
    || '|code action.issue_coa=' || (SELECT count(*) FROM permissions WHERE code = 'action.issue_coa')
    || '|document type COA=' || (SELECT count(*) FROM document_types WHERE prefix = 'COA')
    || '|chemistry view=' || (to_regclass('public.output_batch_chemistry_certainty') IS NOT NULL);
SELECT 'BUCKETS|' || string_agg(id || ':' || CASE WHEN public THEN 'public' ELSE 'private' END
    || ':' || (SELECT count(*) FROM storage.objects o WHERE o.bucket_id = b.id), ',' ORDER BY id) FROM storage.buckets b;
SELECT 'WAREHOUSE_REQUESTS|' || COALESCE(string_agg(kind || '/' || status || '=' || n, ',' ORDER BY kind, status), 'none')
  FROM (SELECT kind, status, count(*) n FROM warehouse_requests GROUP BY 1, 2) x;
SELECT 'WR_KIND_CHECK|' || pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.conrelid = 'public.warehouse_requests'::regclass
   AND c.contype = 'c' AND pg_get_constraintdef(c.oid) LIKE '%kind%';

-- 3 · standing state
SELECT 'S|approvals_on=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '?') || '|l2=' || COALESCE(approval_level2_role_code, '?')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '?') FROM finance_settings;
SELECT 'S|accounts=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) || '|deleted=' || count(*) FILTER (WHERE deleted_at IS NOT NULL)
  FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'S|account|' || u.email || '|banned_until=' || COALESCE(u.banned_until::text, '-') || '|' || string_agg(r.code, ',' ORDER BY r.code) FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email, u.banned_until ORDER BY u.email;
SELECT 'S|role codes|' || string_agg(r.code || '=' || (SELECT count(*) FROM role_permissions rp WHERE rp.role_id = r.id), ',' ORDER BY r.code) FROM roles r;
SELECT 'S|issue_coa roles|' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), 'none') FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code = 'action.issue_coa';
SELECT 'S|throwaway accounts=' || count(*) FROM auth.users WHERE email LIKE '%@test.local';
SELECT 'S|probe roles=' || count(*) FROM roles WHERE code LIKE 'probe-%';
SELECT 'S|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL');
SELECT 'S|catalogue=' || (SELECT count(*) FROM permissions) || '|admin=' || (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'S|change_log rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
SELECT 'S|document_types=' || count(*) FROM document_types;
SELECT 'S|public base tables=' || count(*) FROM pg_tables WHERE schemaname = 'public';
ROLLBACK;
