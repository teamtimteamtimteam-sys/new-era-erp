-- MES-8b-2 close-out — window readings, read-only (BEGIN READ ONLY … ROLLBACK), as postgres (rolbypassrls = true), base tables and the catalog.
-- The window: migration commit 2026-10-17 13:42:39 CST → push of 4236db6a 2026-10-19 09:49:03 CST (lower bound of the end)
--             → this session's first command 2026-10-19 09:59:02 CST (upper bound; rests on Tim's "deployed").
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-9/mes8b2-closeout-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'FLOOR|role=' || (SELECT count(*) FROM roles WHERE code = 'floor_display')
    || '|holders_of_role=' || (SELECT count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'floor_display' AND ur.revoked_at IS NULL)
    || '|v28_refresh=' || COALESCE((SELECT refresh_seconds::text FROM floor_board_settings), 'NULL')
    || '|v28_tiles=' || COALESCE((SELECT tiles::text FROM floor_board_settings), 'NULL');
SELECT 'HOLDERS|' || rp.permission_code || '|' || string_agg(r.code, ',' ORDER BY r.code)
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'data.view_floor_board' GROUP BY rp.permission_code;
SELECT 'CATALOGUE|' || count(*) || '|module=' || count(*) FILTER (WHERE code LIKE 'module.%') || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%')
    || '|data=' || count(*) FILTER (WHERE code LIKE 'data.%') FROM permissions;
SELECT 'ROLES|' || r.code || '|codes=' || count(rp.permission_code) || '|active=' || r.is_active
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id WHERE r.deleted_at IS NULL GROUP BY r.code, r.is_active ORDER BY 1;
SELECT 'ACCOUNTS|' || count(*) || '|banned=' || count(*) FILTER (WHERE banned_until IS NOT NULL AND banned_until > now()) FROM auth.users;
SELECT 'ACCOUNT|' || u.email || '|' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '-')
  FROM auth.users u LEFT JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL LEFT JOIN roles r ON r.id = ur.role_id GROUP BY u.email ORDER BY 1;
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') || '|locked_before=' || COALESCE(locked_before::text, 'NULL') FROM finance_settings;
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'CODS|' || c.code || '|sha=' || i.sha256 FROM certificates_of_destruction c JOIN cod_issues i ON i.cod_id = c.id ORDER BY c.code;
SELECT 'COD_OBJECTS|' || o.name || '|' || (o.metadata ->> 'size') || '|' || (o.metadata ->> 'eTag') FROM storage.objects o WHERE o.bucket_id = 'cod-documents' ORDER BY o.name;
SELECT 'VIEWS|' || count(*) || '|writable_pairs=' || (SELECT count(*) FROM pg_class c2 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
        CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r) CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
        WHERE n2.nspname = 'public' AND c2.relkind = 'v' AND has_table_privilege(g.r, c2.oid, p.priv))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'v';
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'TABLES|' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r';
-- the window, by table and operation (change_log is the record of every write to a logged table)
SELECT 'WINDOW_CL|' || cl.table_name || '|' || cl.op || '|' || count(*) || '|' || to_char(min(cl.occurred_at) AT TIME ZONE 'Asia/Singapore', 'MM-DD HH24:MI:SS')
    || '–' || to_char(max(cl.occurred_at) AT TIME ZONE 'Asia/Singapore', 'MM-DD HH24:MI:SS')
  FROM change_log cl WHERE cl.occurred_at >= '2026-10-17 13:42:39+08' AND cl.occurred_at < '2026-10-19 09:59:02+08'
 GROUP BY cl.table_name, cl.op ORDER BY 1;
-- after the MES-8b-2 session's own closing readings (14:35:26) and before this session: who wrote what
SELECT 'AFTER_8B2_SESSION|' || count(*) FROM change_log WHERE occurred_at >= '2026-10-17 14:35:26+08' AND occurred_at < '2026-10-19 09:59:02+08';
SELECT 'AFTER_8B2_SESSION_BY|' || cl.table_name || '|' || cl.op || '|' || COALESCE(u.email, cl.actor_account::text, cl.actor_kind) || '|' || count(*)
    || '|' || to_char(min(cl.occurred_at) AT TIME ZONE 'Asia/Singapore', 'MM-DD HH24:MI') || '–' || to_char(max(cl.occurred_at) AT TIME ZONE 'Asia/Singapore', 'MM-DD HH24:MI')
  FROM change_log cl LEFT JOIN auth.users u ON u.id = cl.actor_account
 WHERE cl.occurred_at >= '2026-10-17 14:35:26+08' AND cl.occurred_at < '2026-10-19 09:59:02+08'
 GROUP BY cl.table_name, cl.op, COALESCE(u.email, cl.actor_account::text, cl.actor_kind) ORDER BY 1;
SELECT 'AFTER_PUSH_BEFORE_SESSION|' || count(*) FROM change_log WHERE occurred_at >= '2026-10-19 09:49:03+08' AND occurred_at < '2026-10-19 09:59:02+08';
SELECT 'SINCE_SESSION|' || count(*) FROM change_log WHERE occurred_at >= '2026-10-19 09:59:02+08';
SELECT 'CL_MAX|' || count(*) || '|max_seq=' || max(seq) FROM change_log;
ROLLBACK;
