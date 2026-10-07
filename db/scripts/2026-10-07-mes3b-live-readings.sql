-- db/scripts/2026-10-07-mes3b-live-readings.sql
-- MES-3b · 线上的前后读数,补在 2026-10-06-mes1-live-readings.sql 后面 —— 只读,以 postgres(rolbypassrls = true)读【基表】。
--   ① materials 加了两列:按【迁移前就有的那几列】(ordinal 顺序)重算同一个指纹 —— 与迁移前那一份 mes1 读数里 materials 一行直接可比。
--   ② MES-3b 的东西在线上一样都没设:没有一种物料有 UN 编号或 HS 编码;字典是引导(四个编号、标记三列全空;六张模板);两张日志表是空的;
--      MES-3a 的东西也照旧一样都没设;校准开关空着。
WITH alt(tbl, newcols) AS (VALUES ('materials', ARRAY['dg_code', 'hs_code'])),
cols AS (
    SELECT a.tbl, string_agg(format('x.%I', att.attname), ', ' ORDER BY att.attnum) AS oldcols
      FROM alt a JOIN pg_attribute att ON att.attrelid = ('public.' || a.tbl)::regclass
     WHERE att.attnum > 0 AND NOT att.attisdropped AND NOT (att.attname = ANY (a.newcols))
     GROUP BY a.tbl
)
SELECT tbl || ' (pre-MES-3b columns)' AS tbl,
       (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', tbl), false, true, '')))[1]::text AS n,
       left((xpath('/row/d/text()', query_to_xml(format(
           'SELECT md5(COALESCE(string_agg(md5(row(%s)::text), '''' ORDER BY md5(row(%s)::text)), '''')) AS d FROM public.%I x', oldcols, oldcols, tbl),
           false, true, '')))[1]::text, 12) AS digest
  FROM cols
UNION ALL SELECT '~mes3b set on live',
       'materials with a UN number ' || (SELECT count(*) FROM materials WHERE dg_code IS NOT NULL)
       || ' · with an HS code ' || (SELECT count(*) FROM materials WHERE hs_code IS NOT NULL),
       'DG codes ' || (SELECT string_agg(code || ':' || dg_class, ',' ORDER BY code) FROM dangerous_goods_codes)
       || ' · DG with marking/packing/size ' || (SELECT count(*) FROM dangerous_goods_codes
                                                 WHERE marking_text IS NOT NULL OR packing_instruction IS NOT NULL OR label_size IS NOT NULL)
       || ' · templates ' || (SELECT string_agg(code, ',' ORDER BY sort_order) FROM label_templates)
       || ' · label prints ' || (SELECT count(*) FROM label_prints) || ' · scans ' || (SELECT count(*) FROM scan_events)
UNION ALL SELECT '~mes3a still unset', 'categories ' || (SELECT count(*) FROM nea_waste_categories) || ' · ceilings ' || (SELECT count(*) FROM licence_storage_limits),
       'dwell periods ' || (SELECT count(*) FROM inbound_safety_states WHERE dwell_warning_days IS NOT NULL)
       || ' · quarantine locations ' || (SELECT count(*) FROM storage_locations WHERE is_quarantine)
       || ' · calibration switch ' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
ORDER BY 1;
