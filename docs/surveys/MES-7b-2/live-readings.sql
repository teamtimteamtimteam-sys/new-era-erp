-- MES-7b-1 close-out + MES-7b-2 — opening and closing live readings (2026-10-16), read-only: BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r') and the catalog, so counts are real row counts, not a permission answer
-- (AGENTS.md「一个『0 行』的读数,先问它是谁读的」). The two reconciliations resolve the reader's codes and postgres carries no JWT, so they are read
-- in the same transaction as tim@ (634c00f9…, role cfo), switched to `authenticated` with that sub (read only, no write possible).
-- The view-grant lines read the CATALOG (has_table_privilege), not behaviour; behaviour is measured by docs/surveys/MES-7b-2/view-writes.sql.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-7b-2/live-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- codes
SELECT 'HOLDERS|' || p.code || '=' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '')
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.processing.view', 'data.view_health', 'module.quality.edit', 'action.ncr_decide', 'action.issue_coa',
                  'module.safety.view', 'module.safety.edit', 'module.tasks.view', 'module.tasks.edit')
 GROUP BY p.code ORDER BY p.code;
SELECT 'CATALOGUE|' || count(*) || '|module=' || count(*) FILTER (WHERE code LIKE 'module.%') || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%')
    || '|data=' || count(*) FILTER (WHERE code LIKE 'data.%') FROM permissions;
-- MES-7b-1's objects, in the window and after
SELECT 'INCIDENTS|' || count(*) || '|md5=' || COALESCE(md5(string_agg(to_jsonb(i)::text, '' ORDER BY id)), '-') FROM incidents i;
SELECT 'INCIDENT_UPDATES|' || count(*) FROM incident_updates;
SELECT 'INCIDENT_LINKS|' || count(*) FROM incident_batches;
SELECT 'HANDOVER_INCIDENT_REFS|' || count(*) FROM shift_handover_incident_refs;
SELECT 'INCIDENT_KINDS|' || string_agg(code || ':' || is_active, ',' ORDER BY sort_order) FROM incident_kinds;
SELECT 'V19|days=' || COALESCE(nea_report_working_days::text, 'NULL') || '|confirmed_at=' || COALESCE(nea_report_days_confirmed_at::text, 'NULL') FROM safety_settings;
SELECT 'NOTE|spare_part|' || COALESCE(notes, '') FROM material_kinds WHERE code = 'spare_part';
-- MES-7b-2's objects (absent before the migration)
SELECT 'INSPECTION_TABLES|' || COALESCE(string_agg(tablename, ',' ORDER BY tablename), 'none') FROM pg_tables
 WHERE schemaname = 'public' AND (tablename LIKE 'inspection%' OR tablename LIKE 'environmental%');
SELECT 'DOCTYPES|' || count(*) || '|INS=' || count(*) FILTER (WHERE prefix = 'INS') || '|INC=' || count(*) FILTER (WHERE prefix = 'INC') FROM document_types;
SELECT 'LABORATORIES|' || count(*) || '|active=' || count(*) FILTER (WHERE is_active) FROM laboratories;
SELECT 'NCR|' || count(*) || '|sources used=' || COALESCE(string_agg(DISTINCT source, ','), '-') FROM nonconformance_reports;
SELECT 'NCR_SOURCE_CHECK|' || left(pg_get_constraintdef(oid), 220) FROM pg_constraint
 WHERE conrelid = 'public.nonconformance_reports'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%source%';
SELECT 'TASKS|' || count(*) || '|not deleted=' || count(*) FILTER (WHERE deleted_at IS NULL) || '|md5=' || md5(string_agg(to_jsonb(t)::text, '' ORDER BY id)) FROM tasks t;
SELECT 'EMPLOYEES|' || count(*) || '|not deleted=' || count(*) FILTER (WHERE deleted_at IS NULL) FROM employees;
SELECT 'LOCATIONS|' || count(*) FROM storage_locations;
-- F16: the view write grants, as the catalog states them (behaviour: view-writes.sql)
SELECT 'VIEWS|' || count(*) || '|owner-rights=' || count(*) FILTER (WHERE NOT COALESCE(c.reloptions::text LIKE '%security_invoker=on%' OR c.reloptions::text LIKE '%security_invoker=true%', false))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'v';
SELECT 'VIEW_GRANTS|' || g.r || '|insert=' || count(*) FILTER (WHERE has_table_privilege(g.r, c.oid, 'INSERT'))
    || '|update=' || count(*) FILTER (WHERE has_table_privilege(g.r, c.oid, 'UPDATE'))
    || '|delete=' || count(*) FILTER (WHERE has_table_privilege(g.r, c.oid, 'DELETE'))
    || '|truncate=' || count(*) FILTER (WHERE has_table_privilege(g.r, c.oid, 'TRUNCATE'))
    || '|any write=' || count(*) FILTER (WHERE has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
                                            OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE'))
    || '|select=' || count(*) FILTER (WHERE has_table_privilege(g.r, c.oid, 'SELECT'))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
 WHERE n.nspname = 'public' AND c.relkind = 'v' GROUP BY g.r ORDER BY g.r;
SELECT 'DEFAULT_ACL|' || pg_get_userbyid(d.defaclrole) || '|' || COALESCE(n.nspname, '*') || '|' || d.defaclobjtype::text || '|' || d.defaclacl::text
  FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace ORDER BY 1;
-- standing state
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') FROM finance_settings;
SELECT 'ACCOUNTS_LOGIN|all=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'ACCOUNT|' || u.email || '|' || string_agg(r.code, ',' ORDER BY r.code) FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email ORDER BY u.email;
SELECT 'ROLECODES|' || string_agg(r.code || '=' || n, ' ' ORDER BY r.code)
  FROM (SELECT role_id, count(*) n FROM role_permissions GROUP BY role_id) x JOIN roles r ON r.id = x.role_id;
SELECT 'ROLEPERMS_MD5|' || md5(string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'THROWAWAY|accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'COD|' || c.code || '|' || c.status || '|recorded sha256=' || COALESCE(i.sha256, '-') || '|snapshot md5=' || COALESCE(md5(c.snapshot::text), '-')
  FROM certificates_of_destruction c LEFT JOIN cod_issues i ON i.cod_id = c.id WHERE c.status = 'issued' ORDER BY c.code;
SELECT 'COD_BUCKET|objects=' || count(*) || '|' || COALESCE(string_agg(name || ':' || COALESCE(metadata ->> 'size', '?') || ':' || COALESCE(metadata ->> 'eTag', '?'), ',' ORDER BY name), '')
  FROM storage.objects WHERE bucket_id = 'cod-documents';
SELECT 'JOURNAL|entries=' || (SELECT count(*) FROM journal_entries) || '|lines=' || (SELECT count(*) FROM journal_lines)
    || '|md5 entries=' || (SELECT md5(string_agg(to_jsonb(e)::text, '' ORDER BY id)) FROM journal_entries e);
SELECT 'BATCHES|' || count(*) || '|md5=' || md5(string_agg(to_jsonb(b)::text, '' ORDER BY id)) FROM inbound_batches b;
SELECT 'OUTPUT_BATCHES|' || count(*) || '|md5=' || md5(string_agg(to_jsonb(b)::text, '' ORDER BY id)) FROM output_batches b;
SELECT 'MOVEMENTS|' || count(*) || '|md5=' || md5(string_agg(to_jsonb(m)::text, '' ORDER BY id)) FROM inventory_movements m;
SELECT 'SAFETYSTATE_ROWS|' || count(*) || '|md5=' || COALESCE(md5(string_agg(to_jsonb(s)::text, '' ORDER BY id)), '-') FROM inbound_batch_safety_states s;
SELECT 'DOWNTIME|' || count(*) || '|md5=' || COALESCE(md5(string_agg(to_jsonb(d)::text, '' ORDER BY id)), '-') FROM equipment_downtime d;
SELECT 'CHANGELOG|rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
-- the MES-7b-1 window (start 15:49:13 CST, measured) and after: change-log rows by table and op
SELECT 'WINDOWLOG|' || table_name || '|' || op || '|' || count(*) || '|' || to_char(min(occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS')
    || '–' || to_char(max(occurred_at) AT TIME ZONE 'Asia/Singapore', 'HH24:MI:SS')
  FROM change_log WHERE occurred_at >= timestamptz '2026-10-16 15:49:13+08' GROUP BY table_name, op ORDER BY table_name, op;
SELECT 'AFTERPUSHLOG|' || count(*) FROM change_log WHERE occurred_at >= timestamptz '2026-10-16 16:54:08+08';
SELECT 'TABLES|' || count(*) FROM pg_tables WHERE schemaname = 'public';
-- reconciliations in tim@'s session
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) IS NOT NULL AS as_tim;
SET LOCAL ROLE authenticated;
SELECT 'RECON|' || (s ->> 'side') || '|list=' || (s ->> 'list_base') || '|ledger=' || (s ->> 'ledger_base') || '|unexplained=' || (s ->> 'unexplained_base')
  FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s;
SELECT 'INVCTL|' || (s ->> 'side') || '|ledger=' || (s ->> 'ledger_base') || '|subledger=' || (s ->> 'subledger_base') || '|unexplained='
    || COALESCE(s ->> 'unexplained_base', 'NULL') || '|reconciled=' || COALESCE(s ->> 'reconciled', 'NULL')
  FROM jsonb_array_elements(gl_control_reconciliation(CURRENT_DATE) -> 'sides') s WHERE s ->> 'side' LIKE 'inventory%';
RESET ROLE;
ROLLBACK;
