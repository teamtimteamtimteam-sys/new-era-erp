-- MES-7b Step 0 — live facts the grilling rests on. Read-only (BEGIN READ ONLY … ROLLBACK) as postgres (rolbypassrls = true), base tables and the
-- catalog only (no gated view is read here: postgres carries no JWT, so a has_permission() view would read empty — AGENTS.md「一个『0 行』的读数」).
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-7b/live-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- who would hold module.safety.view / .edit under MES-0 Q90 (view = every role holding module.processing.view + cfo; edit = cto, warehouse, admin)
SELECT 'HOLDERS|' || p.code || '=' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '')
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.processing.view', 'module.processing.edit', 'module.quality.edit', 'data.view_health', 'module.hr.view', 'module.inventory.view',
                  'action.processing_aftercare')
 GROUP BY p.code ORDER BY p.code;
SELECT 'SAFETY_CODES|' || count(*) FROM permissions WHERE code LIKE 'module.safety.%';
SELECT 'CATALOGUE|' || count(*) || '|module=' || count(*) FILTER (WHERE code LIKE 'module.%') || '|action=' || count(*) FILTER (WHERE code LIKE 'action.%')
    || '|data=' || count(*) FILTER (WHERE code LIKE 'data.%') FROM permissions;
-- people: who can be named as injured / inspector
SELECT 'EMPLOYEES|' || count(*) || '|active=' || count(*) FILTER (WHERE deleted_at IS NULL) FROM employees;
-- working-day deadline: the holiday calendar the deadline would read
SELECT 'HOLIDAYS|' || y || '|' || n || '|active=' || a
  FROM (SELECT extract(year FROM holiday_date)::int AS y, count(*) AS n, count(*) FILTER (WHERE is_active) AS a FROM public_holidays GROUP BY 1) h ORDER BY y;
-- ingestion: the class MES-1 registered for incidents, devices by kind, inbox rows of that class
SELECT 'CLASS|' || code || '|target=' || target_en || '|transform=' || COALESCE(transform_function, 'NULL') || '|manual=' || COALESCE(manual_entry_code, 'NULL')
    || '|creates_draft=' || creates_draft || '|active=' || is_active FROM ingest_data_classes WHERE code = 'safety_alarm';
SELECT 'DEVICES|' || kind || '=' || count(*) FROM devices GROUP BY kind ORDER BY kind;
SELECT 'INBOX|safety_alarm=' || count(*) FROM ingest_inbox WHERE data_class = 'safety_alarm';
-- run exception events and their types
SELECT 'EVTYPE|' || code || '|active=' || is_active FROM processing_event_types ORDER BY sort_order, code;
SELECT 'RUNEVENTS|' || count(*) || '|safety_alarm=' || count(*) FILTER (WHERE event_type_code = 'safety_alarm') FROM processing_run_events;
-- NCRs and their sources
SELECT 'NCR|' || count(*) || '|' || COALESCE(string_agg(DISTINCT source, ','), '-') FROM nonconformance_reports;
-- downtime, tasks, locations, safety states (things an incident may cite)
SELECT 'DOWNTIME|' || count(*) FROM equipment_downtime;
SELECT 'TASKS|' || count(*) FROM tasks;
SELECT 'LOCATIONS|' || count(*) || '|quarantine=' || count(*) FILTER (WHERE is_quarantine) FROM storage_locations;
SELECT 'SAFETYSTATES|' || string_agg(code, ',' ORDER BY sort_order) FROM inbound_safety_states;
SELECT 'MOVES_WITH_LOCATION|' || count(*) FILTER (WHERE location_id IS NOT NULL) || '/' || count(*) FROM inventory_movements;
SELECT 'RUNS_WITH_MACHINE_TIMES|' || count(*) FILTER (WHERE equipment_id IS NOT NULL AND started_at IS NOT NULL) || '/' || count(*) FROM processing_runs;
SELECT 'DOCTYPES|' || count(*) || '|INC=' || count(*) FILTER (WHERE prefix = 'INC') || '|INS=' || count(*) FILTER (WHERE prefix = 'INS') FROM document_types;
SELECT 'COMPLIANCE|licences=' || count(*) FROM company_compliance;
SELECT 'TABLES|' || count(*) FROM pg_tables WHERE schemaname = 'public';
SELECT 'ARMS|operations_now=' || (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g'))
    || '|pending_values=' || (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g'));
SELECT 'NOTE|spare_part|' || left(notes, 40) FROM material_kinds WHERE code = 'spare_part';
ROLLBACK;
