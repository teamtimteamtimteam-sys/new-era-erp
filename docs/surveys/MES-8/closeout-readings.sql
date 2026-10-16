-- MES-7b-2 close-out — window readings, read-only (BEGIN READ ONLY … ROLLBACK), as postgres (rolbypassrls = true), base tables.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-8/closeout-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'SAFETY|templates=' || (SELECT count(*) FROM inspection_templates) || '|items=' || (SELECT count(*) FROM inspection_template_items)
    || '|runs=' || (SELECT count(*) FROM inspection_runs) || '|results=' || (SELECT count(*) FROM inspection_results)
    || '|findings=' || (SELECT count(*) FROM inspection_findings) || '|closures=' || (SELECT count(*) FROM inspection_finding_closures)
    || '|parameters=' || (SELECT count(*) FROM environmental_parameters) || '|env_results=' || (SELECT count(*) FROM environmental_results)
    || '|incidents=' || (SELECT count(*) FROM incidents) || '|ncrs=' || (SELECT count(*) FROM nonconformance_reports)
    || '|tasks=' || (SELECT count(*) FROM tasks);
SELECT 'VIEWS|' || count(*) || '|writable_pairs=' || (SELECT count(*) FROM pg_class c2 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
        CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r) CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
        WHERE n2.nspname = 'public' AND c2.relkind = 'v' AND has_table_privilege(g.r, c2.oid, p.priv))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'v';
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') FROM finance_settings;
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'ACCOUNTS|' || count(*) || '|banned=' || count(*) FILTER (WHERE banned_until IS NOT NULL AND banned_until > now())
    || '|throwaway=' || count(*) FILTER (WHERE email LIKE '%@test.local') FROM auth.users;
SELECT 'CODS|' || c.code || '|sha=' || i.sha256 FROM certificates_of_destruction c JOIN cod_issues i ON i.cod_id = c.id ORDER BY c.code;
SELECT 'COD_OBJECTS|' || o.name || '|' || (o.metadata ->> 'size') FROM storage.objects o WHERE o.bucket_id = 'cod-documents' ORDER BY o.name;
-- the window: migration commit 19:03:57 → this session's first command 19:57:20 (CST)
SELECT 'WINDOW_CL|' || cl.table_name || '|' || cl.op || '|' || count(*) || '|' || to_char(min(cl.occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS')
    || '–' || to_char(max(cl.occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS')
  FROM change_log cl WHERE cl.occurred_at >= '2026-10-16 19:03:57+08' AND cl.occurred_at < '2026-10-16 19:57:20+08'
 GROUP BY cl.table_name, cl.op ORDER BY 1;
SELECT 'AFTER_PUSH_BEFORE_SESSION|' || count(*) FROM change_log WHERE occurred_at >= '2026-10-16 19:53:32+08' AND occurred_at < '2026-10-16 19:57:20+08';
ROLLBACK;
