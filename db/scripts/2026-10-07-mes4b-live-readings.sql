-- db/scripts/2026-10-07-mes4b-live-readings.sql
-- MES-4b · 线上的前后读数,补在 2026-10-06-mes1-live-readings.sql 后面 —— 只读,以 postgres(rolbypassrls = true)读【基表】。
--   ① 本刀给几张既有表加了列:按【去掉新列】的整行(to_jsonb(行) - 新列;去掉一个还不存在的键是空操作)算同一个指纹,
--      所以迁移前后直接可比 —— 每一批进料与产出、每一条损耗行、每一道工序、每一种形态、每一类损耗都不该动(除了新列与引导的行)。
--   ② 本刀在线上【只设】它点名的那几样:新列全空(批次的结构 · 份额 · 警戒线);勾电解液的工序 0;要求结构的工序两道;损耗行全是 measured。
--   跑法:psql "<pooler dsn>" -X -A -f 本文件(迁移前一次、全部验证之后一次)。
\pset pager off
\pset format unaligned
BEGIN READ ONLY;
SELECT 'stable', t, n, left(d, 12) FROM (
    SELECT 'inbound_batches' AS t, count(*) AS n, md5(COALESCE(string_agg((to_jsonb(x) - 'cell_construction_code')::text, '|' ORDER BY x.id), '')) AS d FROM inbound_batches x
    UNION ALL SELECT 'output_batches', count(*), md5(COALESCE(string_agg((to_jsonb(x) - 'cell_construction_code')::text, '|' ORDER BY x.id), '')) FROM output_batches x
    UNION ALL SELECT 'processing_run_losses', count(*), md5(COALESCE(string_agg((to_jsonb(x) - 'basis' - 'derived_share_pct')::text, '|' ORDER BY x.id), '')) FROM processing_run_losses x
    UNION ALL SELECT 'processing_runs', count(*), md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '')) FROM processing_runs x
    UNION ALL SELECT 'operation_types (pre-MES-4b rows)', count(*), md5(COALESCE(string_agg((to_jsonb(x) - 'electrolyte_share_pct' - 'electrolyte_loss_applies' - 'requires_cell_construction')::text, '|' ORDER BY x.code), '')) FROM operation_types x
    UNION ALL SELECT 'material_forms (pre-MES-4b rows)', count(*), md5(COALESCE(string_agg((to_jsonb(x) - 'output_document_key')::text, '|' ORDER BY x.code), '')) FROM material_forms x
        WHERE x.code NOT IN ('cathode_powder', 'anode_powder', 'copper_foil', 'aluminium_foil', 'collected_dust', 'harness_bms_busbar')
    UNION ALL SELECT 'loss_categories (other than electrolyte)', count(*), md5(COALESCE(string_agg((to_jsonb(x) - 'may_be_derived')::text, '|' ORDER BY x.code), '')) FROM loss_categories x
        WHERE x.code <> 'electrolyte_evaporation'
    UNION ALL SELECT 'materials', count(*), md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '')) FROM materials x
) s ORDER BY t;
SELECT 'set', 'batches with construction', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.inbound_batches'::regclass AND attname = 'cell_construction_code')
        THEN 'SELECT (SELECT count(*) FROM inbound_batches WHERE cell_construction_code IS NOT NULL) + (SELECT count(*) FROM output_batches WHERE cell_construction_code IS NOT NULL) AS n'
        ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?');
SELECT 'set', 'operations with electrolyte flag or share', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.operation_types'::regclass AND attname = 'electrolyte_loss_applies')
        THEN 'SELECT count(*) AS n FROM operation_types WHERE electrolyte_loss_applies OR electrolyte_share_pct IS NOT NULL' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?');
SELECT 'set', 'operations requiring construction', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.operation_types'::regclass AND attname = 'requires_cell_construction')
        THEN 'SELECT string_agg(code, '','' ORDER BY code) AS n FROM operation_types WHERE requires_cell_construction' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '(none)');
SELECT 'set', 'V11 warning levels set', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN to_regclass('public.contamination_streams') IS NOT NULL
        THEN 'SELECT count(*) AS n FROM contamination_streams WHERE warning_pct IS NOT NULL' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?');
SELECT 'set', 'contamination checks', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN to_regclass('public.contamination_checks') IS NOT NULL
        THEN 'SELECT count(*) AS n FROM contamination_checks' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?');
SELECT 'set', 'loss rows not measured', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.processing_run_losses'::regclass AND attname = 'basis')
        THEN 'SELECT count(*) AS n FROM processing_run_losses WHERE basis <> ''measured''' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?');
SELECT 'set', 'require_calibrated_since', COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL');
SELECT 'set', 'material forms / document types / output-form rows', (SELECT count(*) FROM material_forms) || ' / ' || (SELECT count(*) FROM document_types) || ' / ' || (SELECT count(*) FROM operation_type_output_forms);
SELECT 'set', 'sequences output/inbound', (SELECT last_value FROM output_code_seq) || ' / ' || (SELECT last_value FROM inbound_code_seq);
ROLLBACK;
