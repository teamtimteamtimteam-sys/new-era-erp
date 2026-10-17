-- MES-8b-1 close-out — window readings, read-only (BEGIN READ ONLY … ROLLBACK), as postgres (rolbypassrls = true), base tables and the catalog.
-- The window: migration commit 2026-10-17 02:30:23 CST → this session's first command 2026-10-17 11:24:50 CST (push of f084de52 at 03:23:30).
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-8b-2/closeout-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'MES8B1|packs=' || (SELECT count(*) FROM compliance_packs) || '|pack_issues=' || (SELECT count(*) FROM compliance_pack_issues)
    || '|settings_rows=' || (SELECT count(*) FROM compliance_settings)
    || '|cpk_objects=' || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'compliance-documents');
SELECT 'PERIODS|locked_before=' || COALESCE(locked_before::text, 'NULL') || '|system_start=' || COALESCE(system_start_date::text, 'NULL') FROM finance_settings;
SELECT 'INBOUND_FOR_PROBE|' || ib.id || '|' || ib.code || '|runs_consuming=' ||
       (SELECT count(*) FROM processing_inputs pi WHERE pi.inbound_batch_id = ib.id)
  FROM inbound_batches ib WHERE ib.deleted_at IS NULL ORDER BY ib.code LIMIT 40;
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
 WHERE rp.permission_code IN ('module.compliance.view', 'action.compliance_pack') GROUP BY rp.permission_code ORDER BY 1;
SELECT 'CODS|' || c.code || '|sha=' || i.sha256 FROM certificates_of_destruction c JOIN cod_issues i ON i.cod_id = c.id ORDER BY c.code;
SELECT 'COD_OBJECTS|' || o.name || '|' || (o.metadata ->> 'size') FROM storage.objects o WHERE o.bucket_id = 'cod-documents' ORDER BY o.name;
SELECT 'WINDOW_CL|' || cl.table_name || '|' || cl.op || '|' || count(*) || '|' || to_char(min(cl.occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS')
    || '–' || to_char(max(cl.occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS')
  FROM change_log cl WHERE cl.occurred_at >= '2026-10-17 02:30:23+08' AND cl.occurred_at < '2026-10-17 11:24:50+08'
 GROUP BY cl.table_name, cl.op ORDER BY 1;
SELECT 'AFTER_PUSH_BEFORE_SESSION|' || count(*) FROM change_log WHERE occurred_at >= '2026-10-17 03:23:30+08' AND occurred_at < '2026-10-17 11:24:50+08';
SELECT 'AFTER_PUSH_BEFORE_SESSION_BY|' || table_name || '|' || op || '|' || count(*) FROM change_log
 WHERE occurred_at >= '2026-10-17 03:23:30+08' AND occurred_at < '2026-10-17 11:24:50+08' GROUP BY table_name, op ORDER BY 1;
SELECT 'SINCE_SESSION|' || count(*) FROM change_log WHERE occurred_at >= '2026-10-17 11:24:50+08';
-- the seven real roles' codes, for the LOCAL harness's clone seed (read only)
SELECT 'ROLECODES|' || r.code || '|' || string_agg(rp.permission_code, ',' ORDER BY rp.permission_code)
  FROM roles r JOIN role_permissions rp ON rp.role_id = r.id
 WHERE r.code IN ('admin', 'cco', 'finance', 'warehouse', 'cto', 'cfo', 'gm') GROUP BY r.code ORDER BY r.code;
ROLLBACK;
