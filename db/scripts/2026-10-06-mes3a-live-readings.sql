-- db/scripts/2026-10-06-mes3a-live-readings.sql
-- MES-3a · 线上的前后读数,补在 2026-10-06-mes1-live-readings.sql 后面 —— 只读,以 postgres(rolbypassrls = true)读【基表】。
--   ① 五张加了列的表:按【迁移前就有的那几列】(ordinal 顺序)重算同一个指纹 —— 与迁移前那一份 mes1 读数里同名一行直接可比
--      (row(...)::text 与整行 x::text 是同一种输出格式)。新列本身另报:它们必须全是空的 / 种子值。
--   ② MES-3a 的东西在线上一样都没设:类别 · 上限 · 上限记录 · 滞留天数 · 隔离标记 · 隔离库位;校准开关空着;两条既有状态行仍开着。
WITH alt(tbl, newcols) AS (VALUES
    ('materials', ARRAY['nea_waste_category_code']),
    ('storage_locations', ARRAY['is_quarantine']),
    ('inbound_safety_states', ARRAY['dwell_warning_days', 'requires_quarantine']),
    ('inbound_batch_safety_states', ARRAY['id', 'created_by_run_id', 'ended_at', 'ended_by', 'end_reason', 'ended_by_run_id', 'reopened_from_id']),
    ('output_batch_safety_states', ARRAY['id', 'created_by_run_id', 'ended_at', 'ended_by', 'end_reason', 'ended_by_run_id', 'reopened_from_id'])
), cols AS (
    SELECT a.tbl, string_agg(format('x.%I', att.attname), ', ' ORDER BY att.attnum) AS oldcols
      FROM alt a JOIN pg_attribute att ON att.attrelid = ('public.' || a.tbl)::regclass
     WHERE att.attnum > 0 AND NOT att.attisdropped AND NOT (att.attname = ANY (a.newcols))
     GROUP BY a.tbl
)
SELECT tbl || ' (pre-MES-3a columns)' AS tbl,
       (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', tbl), false, true, '')))[1]::text AS n,
       left((xpath('/row/d/text()', query_to_xml(format(
           'SELECT md5(COALESCE(string_agg(md5(row(%s)::text), '''' ORDER BY md5(row(%s)::text)), '''')) AS d FROM public.%I x', oldcols, oldcols, tbl),
           false, true, '')))[1]::text, 12) AS digest
  FROM cols
UNION ALL SELECT '~mes3a set on live', 'categories ' || (SELECT count(*) FROM nea_waste_categories) || ' · ceilings ' || (SELECT count(*) FROM licence_storage_limits)
       || ' · ceiling records ' || (SELECT count(*) FROM receipt_ceiling_checks) || ' · materials with a category ' || (SELECT count(*) FROM materials WHERE nea_waste_category_code IS NOT NULL),
       'dwell periods ' || (SELECT count(*) FROM inbound_safety_states WHERE dwell_warning_days IS NOT NULL)
       || ' · requires_quarantine ' || (SELECT string_agg(code || '=' || COALESCE(requires_quarantine::text, 'null'), ',' ORDER BY code) FROM inbound_safety_states)
       || ' · quarantine locations ' || (SELECT count(*) FROM storage_locations WHERE is_quarantine)
       || ' · calibration switch ' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
UNION ALL SELECT '~state rows', 'inbound ' || (SELECT count(*) || ' (' || count(*) FILTER (WHERE ended_at IS NULL) || ' open)' FROM inbound_batch_safety_states),
       'output ' || (SELECT count(*) || ' (' || count(*) FILTER (WHERE ended_at IS NULL) || ' open)' FROM output_batch_safety_states)
ORDER BY 1;
