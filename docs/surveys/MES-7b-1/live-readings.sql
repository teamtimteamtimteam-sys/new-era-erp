-- MES-7b-1 — opening and closing live readings (2026-10-16), read-only: BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r') and the catalog, so counts are real row counts, not a permission answer
-- (AGENTS.md「一个『0 行』的读数,先问它是谁读的」). The two reconciliations resolve the reader's codes and postgres carries no JWT, so they are read
-- in the same transaction as tim@ (634c00f9…, role cfo), switched to `authenticated` with that sub (read only, no write possible).
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-7b-1/live-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- codes: who holds the processing view (→ safety view, Q2), health, quality edit, NCR decide, COA issue; safety codes so far
SELECT 'HOLDERS|' || p.code || '=' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '')
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.processing.view', 'data.view_health', 'module.quality.edit', 'action.ncr_decide', 'action.issue_coa',
                  'module.safety.view', 'module.safety.edit')
 GROUP BY p.code ORDER BY p.code;
SELECT 'SAFETY_CODES|' || count(*) FROM permissions WHERE code LIKE 'module.safety.%';
SELECT 'CATALOGUE|' || count(*) || '|module=' || count(*) FILTER (WHERE code LIKE 'module.%') || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%')
    || '|data=' || count(*) FILTER (WHERE code LIKE 'data.%') FROM permissions;
-- employees (who can be the injured person / the responsible person)
SELECT 'EMPLOYEES|' || count(*) || '|not deleted=' || count(*) FILTER (WHERE deleted_at IS NULL)
    || '|with login=' || count(*) FILTER (WHERE deleted_at IS NULL AND user_id IS NOT NULL) FROM employees;
-- the public-holiday calendar the deadline reads
SELECT 'HOLIDAYS|' || y || '|' || n || '|active=' || a
  FROM (SELECT extract(year FROM holiday_date)::int AS y, count(*) AS n, count(*) FILTER (WHERE is_active) AS a FROM public_holidays GROUP BY 1) h ORDER BY y;
-- where a batch was: locations, movements carrying a location
SELECT 'LOCATIONS|' || count(*) || '|active=' || count(*) FILTER (WHERE is_active) || '|quarantine=' || count(*) FILTER (WHERE is_quarantine) FROM storage_locations;
SELECT 'MOVES_WITH_LOCATION|' || count(*) FILTER (WHERE location_id IS NOT NULL) || '/' || count(*) FROM inventory_movements;
SELECT 'MOVES_BY_LOCATION|' || COALESCE(string_agg(code || '=' || n, ' ' ORDER BY code), '-')
  FROM (SELECT l.code, count(*) n FROM inventory_movements m JOIN storage_locations l ON l.id = m.location_id GROUP BY l.code) x;
-- runs with a machine and times
SELECT 'RUNS|' || count(*) || '|machine=' || count(*) FILTER (WHERE equipment_id IS NOT NULL) || '|machine+start=' || count(*) FILTER (WHERE equipment_id IS NOT NULL AND started_at IS NOT NULL)
    || '|machine+start+end=' || count(*) FILTER (WHERE equipment_id IS NOT NULL AND started_at IS NOT NULL AND ended_at IS NOT NULL) FROM processing_runs;
-- downtime rows, run events
SELECT 'DOWNTIME|' || count(*) || '|open=' || count(*) FILTER (WHERE ended_at IS NULL AND voided_at IS NULL) || '|voided=' || count(*) FILTER (WHERE voided_at IS NOT NULL)
    || '|md5=' || COALESCE(md5(string_agg(to_jsonb(d)::text, '' ORDER BY id)), '-') FROM equipment_downtime d;
SELECT 'RUNEVENTS|' || count(*) || '|md5=' || COALESCE(md5(string_agg(to_jsonb(e)::text, '' ORDER BY id)), '-') FROM processing_run_events e;
-- handovers and their references
SELECT 'HANDOVERS|' || count(*) || '|md5=' || COALESCE(md5(string_agg(to_jsonb(h)::text, '' ORDER BY id)), '-') FROM shift_handovers h;
SELECT 'HANDOVER_ITEMS|' || count(*) FROM shift_handover_items;
SELECT 'HANDOVER_EQUIP_REFS|' || count(*) FROM shift_handover_equipment_refs;
SELECT 'HANDOVER_INCIDENT_REFS|' || CASE WHEN to_regclass('public.shift_handover_incident_refs') IS NULL THEN 'absent' ELSE 'present' END;
-- NCRs and the sources in use
SELECT 'NCR|' || count(*) || '|sources used=' || COALESCE(string_agg(DISTINCT source, ','), '-') FROM nonconformance_reports;
SELECT 'NCR_SOURCE_CHECK|' || left(pg_get_constraintdef(oid), 200) FROM pg_constraint
 WHERE conrelid = 'public.nonconformance_reports'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%source%';
-- incident tables (should be absent before the migration)
SELECT 'INCIDENT_TABLES|' || COALESCE(string_agg(tablename, ',' ORDER BY tablename), 'none') FROM pg_tables
 WHERE schemaname = 'public' AND (tablename LIKE 'incident%' OR tablename = 'safety_settings');
SELECT 'DOCTYPES|' || count(*) || '|INC=' || count(*) FILTER (WHERE prefix = 'INC') FROM document_types;
-- the spare_part note (F12)
SELECT 'NOTE|spare_part|' || COALESCE(notes, '') FROM material_kinds WHERE code = 'spare_part';
SELECT 'KINDS_MD5|' || md5(string_agg(to_jsonb(k)::text, '' ORDER BY code)) FROM material_kinds k;
-- masked tables (column-list SELECT grants), so the new one can be counted against them
SELECT 'MASKED_VIEWS|' || count(*) FROM pg_views WHERE schemaname = 'public' AND viewname LIKE '%\_masked';
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
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code NOT LIKE 'module.safety.%';
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'THROWAWAY|accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'COD|' || c.code || '|' || c.status || '|recorded sha256=' || COALESCE(i.sha256, '-') || '|snapshot md5=' || COALESCE(md5(c.snapshot::text), '-')
  FROM certificates_of_destruction c LEFT JOIN cod_issues i ON i.cod_id = c.id WHERE c.status = 'issued' ORDER BY c.code;
SELECT 'COD_BUCKET|objects=' || count(*) || '|' || COALESCE(string_agg(name || ':' || COALESCE(metadata ->> 'size', '?'), ',' ORDER BY name), '')
  FROM storage.objects WHERE bucket_id = 'cod-documents';
SELECT 'JOURNAL|entries=' || (SELECT count(*) FROM journal_entries) || '|lines=' || (SELECT count(*) FROM journal_lines)
    || '|md5 entries=' || (SELECT md5(string_agg(to_jsonb(e)::text, '' ORDER BY id)) FROM journal_entries e);
SELECT 'BATCHES|' || count(*) || '|md5=' || md5(string_agg(to_jsonb(b)::text, '' ORDER BY id)) FROM inbound_batches b;
SELECT 'MOVEMENTS|' || count(*) || '|md5=' || md5(string_agg(to_jsonb(m)::text, '' ORDER BY id)) FROM inventory_movements m;
SELECT 'SAFETYSTATE_ROWS|' || count(*) || '|md5=' || COALESCE(md5(string_agg(to_jsonb(s)::text, '' ORDER BY id)), '-') FROM inbound_batch_safety_states s;
SELECT 'CHANGELOG|rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
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
