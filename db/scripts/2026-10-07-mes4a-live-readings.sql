-- db/scripts/2026-10-07-mes4a-live-readings.sql
-- MES-4a · 线上的前后读数,补在 2026-10-06-mes1-live-readings.sql 后面 —— 只读,以 postgres(rolbypassrls = true)读【基表】。
--   ① processing_runs / processing_outputs / operation_types 加了列:按【迁移前就有的那几列】(ordinal 顺序)重算同一个指纹 ——
--      与迁移前那一份 mes1 读数里那几行直接可比(14 张在册的加工单、它们的产出腿,一个字节都不该动)。
--      processing_run_losses 是被【重新塑形】的(加了 id / 更正两列,重排了约束):迁移前 0 行,之后也该是 0 行。
--   ② MES-4a 在线上只播了它点名的那几样(两道工序 · Q13 的 27 个字段 · 三类损耗 · 三种事件);
--      机器挂接、配方、容差、范围、班次时刻一样都没设;四张记录表是空的;校准开关空着。
WITH alt(tbl, newcols) AS (VALUES
        ('processing_runs', ARRAY['started_at', 'ended_at', 'shift_code', 'recipe_version_id', 'corrects_run_id']),
        ('processing_outputs', ARRAY['weighing_id']),
        ('operation_types', ARRAY['balance_tolerance_pct'])),
cols AS (
    SELECT a.tbl, string_agg(format('x.%I', att.attname), ', ' ORDER BY att.attnum) AS oldcols, a.newcols
      FROM alt a JOIN pg_attribute att ON att.attrelid = ('public.' || a.tbl)::regclass
     WHERE att.attnum > 0 AND NOT att.attisdropped AND NOT (att.attname = ANY (a.newcols))
     GROUP BY a.tbl, a.newcols
)
SELECT tbl || ' (pre-MES-4a columns' || CASE WHEN tbl = 'operation_types' THEN ', pre-MES-4a rows' ELSE '' END || ')' AS tbl,
       (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I x %s', tbl,
            CASE WHEN tbl = 'operation_types' THEN $w$WHERE x.code NOT IN ('casing_removal', 'electrode_separation')$w$ ELSE '' END),
            false, true, '')))[1]::text AS n,
       left((xpath('/row/d/text()', query_to_xml(format(
           'SELECT md5(COALESCE(string_agg(md5(row(%s)::text), '''' ORDER BY md5(row(%s)::text)), '''')) AS d FROM public.%I x %s', oldcols, oldcols, tbl,
           CASE WHEN tbl = 'operation_types' THEN $w$WHERE x.code NOT IN ('casing_removal', 'electrode_separation')$w$ ELSE '' END),
           false, true, '')))[1]::text, 12) AS digest
  FROM cols
UNION ALL SELECT '~mes4a seeded', 'operation types ' || (SELECT string_agg(code, ',' ORDER BY sort_order) FROM operation_types),
       'loss categories ' || (SELECT string_agg(code, ',' ORDER BY sort_order) FROM loss_categories)
       || ' (the new tables are counted row by row in the mes1 readings)'
UNION ALL SELECT '~mes4a set on live',
       -- 迁移之前这几列还不存在 —— query_to_xml 让同一支查询在前后两次都跑得动(之前那一次这几格是 n/a)
       'tolerances ' || COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.operation_types'::regclass AND attname = 'balance_tolerance_pct')
             THEN 'SELECT count(*) AS n FROM operation_types WHERE balance_tolerance_pct IS NOT NULL' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?')
       || ' · shift times ' || (SELECT count(*) FROM shifts WHERE starts_at IS NOT NULL OR ends_at IS NOT NULL),
       'calibration switch ' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
       || ' · runs with start time ' || COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.processing_runs'::regclass AND attname = 'started_at')
             THEN 'SELECT count(*) AS n FROM processing_runs WHERE started_at IS NOT NULL' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?')
       || ' · outputs with weighing ' || COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.processing_outputs'::regclass AND attname = 'weighing_id')
             THEN 'SELECT count(*) AS n FROM processing_outputs WHERE weighing_id IS NOT NULL' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?')
UNION ALL SELECT '~mes3a/3b still unset', 'categories ' || (SELECT count(*) FROM nea_waste_categories) || ' · ceilings ' || (SELECT count(*) FROM licence_storage_limits),
       'dwell periods ' || (SELECT count(*) FROM inbound_safety_states WHERE dwell_warning_days IS NOT NULL)
       || ' · quarantine locations ' || (SELECT count(*) FROM storage_locations WHERE is_quarantine)
       || ' · UN on materials ' || (SELECT count(*) FROM materials WHERE dg_code IS NOT NULL)
       || ' · HS on materials ' || (SELECT count(*) FROM materials WHERE hs_code IS NOT NULL)
ORDER BY 1;
