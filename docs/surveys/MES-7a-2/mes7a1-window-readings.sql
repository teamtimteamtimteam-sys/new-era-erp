-- MES-7a-1 close-out — what happened on live inside MES-7a-1's broken window (opened 2026-10-16 00:54:58 CST = 2026-10-15 16:54:58 UTC).
-- Read-only (BEGIN READ ONLY … ROLLBACK) as postgres (rolbypassrls = true), base tables. The end of the window is bounded by the first command of
-- this session (2026-10-16 11:12:00 CST = 03:12:00 UTC); rows after it are this close-out's own probe and are reported separately.
-- ★ The change log records writes that happened. A write the database REFUSED (the old app's direct insert on a dropped policy) leaves no row, so
--   "attempted" here can only mean "a row appeared"; a refused attempt is invisible to this reading and is said to be so in the report.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-7a-2/mes7a1-window-readings.sql
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'W|downtime created=' || count(*) FILTER (WHERE created_at >= '2026-10-15 16:54:58+00')
    || '|updated=' || count(*) FILTER (WHERE updated_at >= '2026-10-15 16:54:58+00')
    || '|voided=' || count(*) FILTER (WHERE voided_at >= '2026-10-15 16:54:58+00') || '|rows=' || count(*) FROM equipment_downtime;
SELECT 'W|maintenance created=' || count(*) FILTER (WHERE created_at >= '2026-10-15 16:54:58+00')
    || '|updated=' || count(*) FILTER (WHERE updated_at >= '2026-10-15 16:54:58+00') || '|rows=' || count(*) FROM equipment_maintenance;
SELECT 'W|intervals created=' || count(*) FILTER (WHERE created_at >= '2026-10-15 16:54:58+00')
    || '|updated=' || count(*) FILTER (WHERE updated_at >= '2026-10-15 16:54:58+00') || '|rows=' || count(*) FROM equipment_service_intervals;
SELECT 'W|causes=' || count(*) || '|' || string_agg(code || ':' || class, ',' ORDER BY sort_order, code) FROM downtime_causes;
SELECT 'W|coas=' || (SELECT count(*) FROM certificates_of_analysis) || '|coa_issues=' || (SELECT count(*) FROM coa_issues)
    || '|cods issued in window=' || (SELECT count(*) FROM certificates_of_destruction WHERE issued_at >= '2026-10-15 16:54:58+00')
    || '|cod_issues=' || (SELECT count(*) FROM cod_issues);
SELECT 'W|movements in window=' || count(*) FROM inventory_movements WHERE created_at >= '2026-10-15 16:54:58+00';
SELECT 'CLEQ|' || w || '|' || table_name || '/' || op || '=' || count(*)
  FROM (SELECT CASE WHEN occurred_at < '2026-10-16 03:12:00+00' THEN 'in window' ELSE 'after (this close-out)' END AS w, table_name, op
          FROM change_log WHERE occurred_at >= '2026-10-15 16:54:58+00'
           AND table_name IN ('equipment_downtime', 'equipment_maintenance', 'equipment_service_intervals', 'downtime_causes')) x
 GROUP BY w, table_name, op ORDER BY w, table_name, op;
SELECT 'CL|' || w || '|' || table_name || '/' || op || '=' || count(*)
  FROM (SELECT CASE WHEN occurred_at < '2026-10-16 03:12:00+00' THEN 'in window' ELSE 'after (this close-out)' END AS w, table_name, op
          FROM change_log WHERE occurred_at >= '2026-10-15 16:54:58+00') x
 GROUP BY w, table_name, op ORDER BY w, table_name, op;
SELECT 'CLT|first=' || COALESCE(to_char(min(occurred_at) AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS'), '-')
    || '|last=' || COALESCE(to_char(max(occurred_at) AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS'), '-')
    || '|after push (02:00:51)=' || count(*) FILTER (WHERE occurred_at >= '2026-10-15 18:00:51+00')
  FROM change_log WHERE occurred_at >= '2026-10-15 16:54:58+00' AND occurred_at < '2026-10-16 03:12:00+00';
ROLLBACK;
