-- MES-8a close-out — window readings, read-only (BEGIN READ ONLY … ROLLBACK), as postgres (rolbypassrls = true), base tables and the catalog.
-- The window: migration commit 2026-10-16 22:46:29 CST → this session's first command 2026-10-17 00:11:44 CST (push of 556ef6f4 at 23:54:00).
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-8b-1/closeout-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'MES8A|reviews=' || (SELECT count(*) FROM supplier_scorecard_reviews) || '|statements=' || (SELECT count(*) FROM supplier_statements)
    || '|statement_issues=' || (SELECT count(*) FROM supplier_statement_issues)
    || '|settings_rows=' || (SELECT count(*) FROM supplier_score_settings)
    || '|settings_set=' || (SELECT count(*) FROM supplier_score_settings WHERE weights IS NOT NULL OR grade_lines IS NOT NULL OR review_window_days IS NOT NULL OR grade_caps IS NOT NULL)
    || '|sst_objects=' || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'supplier-statement-documents');
SELECT 'POS|' || count(*) || '|since_window=' || count(*) FILTER (WHERE created_at >= '2026-10-16 22:46:29+08') FROM purchase_orders;
SELECT 'SUPPLIERS_FOR_PROBE|' || s.id || '|' || s.code || '|' || s.status || '|' || s.counterparty_type
  FROM suppliers s WHERE s.deleted_at IS NULL AND s.counterparty_type = 'goods_supplier' ORDER BY s.status, s.code;
SELECT 'VIEWS|' || count(*) || '|writable_pairs=' || (SELECT count(*) FROM pg_class c2 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
        CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r) CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
        WHERE n2.nspname = 'public' AND c2.relkind = 'v' AND has_table_privilege(g.r, c2.oid, p.priv))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'v';
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') FROM finance_settings;
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'ACCOUNTS|' || count(*) || '|banned=' || count(*) FILTER (WHERE banned_until IS NOT NULL AND banned_until > now())
    || '|throwaway=' || count(*) FILTER (WHERE email LIKE '%@test.local') FROM auth.users;
SELECT 'HOLDERS|' || rp.permission_code || '|' || string_agg(r.code, ',' ORDER BY r.code)
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE rp.permission_code IN ('action.supplier_review', 'module.finance.edit') GROUP BY rp.permission_code ORDER BY 1;
SELECT 'CODS|' || c.code || '|sha=' || i.sha256 FROM certificates_of_destruction c JOIN cod_issues i ON i.cod_id = c.id ORDER BY c.code;
SELECT 'COD_OBJECTS|' || o.name || '|' || (o.metadata ->> 'size') FROM storage.objects o WHERE o.bucket_id = 'cod-documents' ORDER BY o.name;
SELECT 'WINDOW_CL|' || cl.table_name || '|' || cl.op || '|' || count(*) || '|' || to_char(min(cl.occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS')
    || '–' || to_char(max(cl.occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS')
  FROM change_log cl WHERE cl.occurred_at >= '2026-10-16 22:46:29+08' AND cl.occurred_at < '2026-10-17 00:11:44+08'
 GROUP BY cl.table_name, cl.op ORDER BY 1;
SELECT 'AFTER_PUSH_BEFORE_SESSION|' || count(*) FROM change_log WHERE occurred_at >= '2026-10-16 23:54:00+08' AND occurred_at < '2026-10-17 00:11:44+08';
SELECT 'SINCE_SESSION|' || count(*) FROM change_log WHERE occurred_at >= '2026-10-17 00:11:44+08';
ROLLBACK;
