-- MES-7a-1 — opening and closing live readings (2026-10-15), read-only: BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables (relkind 'r') and the catalog, so counts are real row counts, not a permission answer.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-7a-1/opening-readings.sql
-- The reconciliation is read separately in tim@'s session (db/scripts/2026-10-05-at1d3-live-recon.sql) — the function filters by the reader's
-- codes, and postgres carries no JWT. The sha256 of the two issued CODs' stored bytes is read separately through the Storage API
-- (docs/surveys/MES-7a-1/cod-bytes-sha.mjs, GET only), because the database holds the recorded hash, not the bytes.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- assets (equipment and other)
SELECT 'ASSET|' || code || '|' || category || '|' || status || '|acq=' || acquisition_date || '|in_service=' || COALESCE(in_service_date::text, '-')
    || '|' || left(description, 50) FROM fixed_assets ORDER BY code;
SELECT 'ASSETS|equipment=' || count(*) FILTER (WHERE category = 'equipment') || '|other=' || count(*) FILTER (WHERE category <> 'equipment') FROM fixed_assets;
-- downtime, maintenance, intervals
SELECT 'DOWNTIME|' || a.code || '|' || to_char(d.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI') || '|end='
    || COALESCE(to_char(d.ended_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI'), 'open')
    || '|voided=' || (d.voided_at IS NOT NULL) || '|reason=' || left(d.reason, 40)
    || '|row=' || md5(to_jsonb(d)::text)
  FROM equipment_downtime d JOIN fixed_assets a ON a.id = d.equipment_id ORDER BY d.started_at;
SELECT 'MAINT|' || a.code || '|' || m.performed_on || '|' || m.kind || '|downtime_linked=' || (m.downtime_id IS NOT NULL)
    || '|expense_linked=' || (m.expense_id IS NOT NULL) || '|capitalised=' || m.capitalised
    || '|capitalised_expense=' || (m.capitalised_expense_id IS NOT NULL) || '|' || left(m.description, 40)
    || '|row=' || md5(to_jsonb(m)::text)
  FROM equipment_maintenance m JOIN fixed_assets a ON a.id = m.equipment_id ORDER BY m.performed_on;
SELECT 'INTERVAL|' || a.code || '|' || i.kind || '|kg=' || COALESCE(i.interval_kg::text, '-') || '|days=' || COALESCE(i.interval_days::text, '-')
    || '|lead_days=' || COALESCE(i.lead_days::text, '-') || '|' || i.disposition || '|row=' || md5(to_jsonb(i)::text)
  FROM equipment_service_intervals i JOIN fixed_assets a ON a.id = i.equipment_id ORDER BY a.code, i.kind;
-- runs with a machine and with times (the MTBF denominator's inputs), and the machine ↔ operation links
SELECT 'RUNS|all=' || count(*) || '|committed live=' || count(*) FILTER (WHERE status = 'committed' AND deleted_at IS NULL)
    || '|with machine=' || count(*) FILTER (WHERE equipment_id IS NOT NULL)
    || '|with start+end=' || count(*) FILTER (WHERE started_at IS NOT NULL AND ended_at IS NOT NULL)
    || '|machine+times=' || count(*) FILTER (WHERE equipment_id IS NOT NULL AND started_at IS NOT NULL AND ended_at IS NOT NULL)
  FROM processing_runs;
SELECT 'OPLINKS|' || count(*) || COALESCE('|' || string_agg(l.operation_type_code || '→' || fa.code, ','), '')
  FROM operation_type_equipment l LEFT JOIN fixed_assets fa ON fa.id = l.fixed_asset_id;
-- certificates of destruction (F10) and of analysis
SELECT 'COD|' || c.code || '|' || c.status || '|issued=' || COALESCE(to_char(c.issued_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI'), '-')
    || '|recorded sha256=' || COALESCE(i.sha256, '-') || '|path=' || COALESCE(i.file_path, '-')
    || '|snapshot md5=' || COALESCE(md5(c.snapshot::text), '-')
  FROM certificates_of_destruction c LEFT JOIN cod_issues i ON i.cod_id = c.id ORDER BY c.code;
SELECT 'COD_BUCKET|objects=' || count(*) || '|' || COALESCE(string_agg(name || ':' || COALESCE(metadata ->> 'size', '?'), ',' ORDER BY name), '')
  FROM storage.objects WHERE bucket_id = 'cod-documents';
SELECT 'COA|all=' || (SELECT count(*) FROM certificates_of_analysis) || '|coa_issues=' || (SELECT count(*) FROM coa_issues)
    || '|coa_void_requests=' || (SELECT count(*) FROM warehouse_requests WHERE kind = 'coa_void');
SELECT 'COA_BUCKET|objects=' || count(*) FROM storage.objects WHERE bucket_id = 'coa-documents';
-- downtime causes (absent before the migration)
SELECT 'CAUSES|' || CASE WHEN to_regclass('public.downtime_causes') IS NULL THEN 'absent' ELSE 'present' END;
-- standing state
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || COALESCE(approval_level1_role_code, '-') || '|l2=' || COALESCE(approval_level2_role_code, '-')
    || '|threshold=' || COALESCE(approval_threshold_base::text, '-') FROM finance_settings;
SELECT 'ACCOUNTS|all=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) || '|deleted=' || count(*) FILTER (WHERE deleted_at IS NOT NULL)
  FROM auth.users WHERE email NOT LIKE '%@test.local';
SELECT 'ACCOUNT|' || u.email || '|banned_until=' || COALESCE(u.banned_until::text, '-') || '|' || string_agg(r.code, ',' ORDER BY r.code) FROM auth.users u
  JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email, u.banned_until ORDER BY u.email;
SELECT 'ROLECODES|' || string_agg(r.code || '=' || n, ' ' ORDER BY r.code)
  FROM (SELECT role_id, count(*) n FROM role_permissions GROUP BY role_id) x JOIN roles r ON r.id = x.role_id;
SELECT 'CATALOGUE|codes=' || (SELECT count(*) FROM permissions)
    || '|admin=' || (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin');
SELECT 'HOLDERS|' || p.code || '=' || COALESCE(string_agg(r.code, ',' ORDER BY r.code), '')
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('action.ncr_decide', 'action.issue_coa', 'action.issue_cod', 'module.processing.edit') GROUP BY p.code ORDER BY p.code;
SELECT 'CALIB|require_calibrated_since=' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'THROWAWAY|accounts=' || (SELECT count(*) FROM auth.users WHERE email LIKE '%@test.local')
    || '|probe roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'probe-%');
SELECT 'PENDING|' || count(*) || '|' || COALESCE(string_agg(to_jsonb(d)::text, ' ; '), '') FROM approval_pending_documents() d;
SELECT 'CHANGELOG|rows=' || count(*) || '|max seq=' || max(seq) FROM change_log;
SELECT 'DOCTYPES|' || count(*) FROM document_types;
SELECT 'TABLES|' || count(*) FROM pg_tables WHERE schemaname = 'public';
SELECT 'BUCKETS|' || count(*) FROM storage.buckets;
ROLLBACK;
