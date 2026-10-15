-- MES-6b-2 close-out — what happened on live inside MES-6b-2's broken window (opened 2026-10-15 20:45:44 CST = 12:45:44 UTC).
-- Read-only (BEGIN READ ONLY … ROLLBACK) as postgres (rolbypassrls = true), base tables. The end of the window is bounded by the first command of
-- this session (22:22:17 CST = 14:22:17 UTC); rows after it are this close-out's own probe and are reported separately.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-7a/mes6b2-window-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'W|coas=' || (SELECT count(*) FROM certificates_of_analysis) || '|coa_issues=' || (SELECT count(*) FROM coa_issues)
    || '|coa_void=' || (SELECT count(*) FROM warehouse_requests WHERE kind = 'coa_void')
    || '|coa bucket objects=' || (SELECT count(*) FROM storage.objects WHERE bucket_id = 'coa-documents');
SELECT 'W|warehouse requests created in window=' || count(*) FROM warehouse_requests WHERE created_at >= '2026-10-15 12:45:44+00';
SELECT 'W|assays created in window=' || count(*) FROM assay_results WHERE created_at >= '2026-10-15 12:45:44+00';
SELECT 'W|ncrs opened in window=' || count(*) FROM nonconformance_reports WHERE opened_at >= '2026-10-15 12:45:44+00';
SELECT 'W|movements in window=' || count(*) FROM inventory_movements WHERE created_at >= '2026-10-15 12:45:44+00';
SELECT 'W|cod issued in window=' || count(*) FROM certificates_of_destruction WHERE issued_at >= '2026-10-15 12:45:44+00';
SELECT 'CL|' || w || '|' || table_name || '/' || op || '=' || count(*)
  FROM (SELECT CASE WHEN occurred_at < '2026-10-15 14:22:17+00' THEN 'in window' ELSE 'after (this close-out)' END AS w, table_name, op
          FROM change_log WHERE occurred_at >= '2026-10-15 12:45:44+00') x
 GROUP BY w, table_name, op ORDER BY w, table_name, op;
ROLLBACK;
