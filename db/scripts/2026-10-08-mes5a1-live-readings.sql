-- db/scripts/2026-10-08-mes5a1-live-readings.sql
-- MES-5a-1 · 线上的前后读数,补在 2026-10-06-mes1-live-readings.sql(逐表指纹)后面 —— 只读,以 postgres(rolbypassrls = true)读【基表】。
--   ① 本刀给四张既有表加了列(inbound_batches / output_batches.module_count · materials.discharge_pass_voltage_v ·
--      operation_types.verifies_by_unit / started_from_run_page):逐表指纹在这四张上【必然】变(行文本多了一格)。
--      所以这里按【去掉新列】的整行(to_jsonb(行) - 新列;去掉一个还不存在的键是空操作)算同一个指纹,迁移前后直接可比。
--      三张挂工序的配置表与关系例外表只比【既有的行】(拆去隔离那一道工序的行与两条新例外是引导的行,另列)。
--   ② 本刀在线上【只设】两样:深度放电的 verifies_by_unit 与 discharge_quarantine_split 那一道工序(连同它的形态 / 状态行)。
--      其余全空:没有一批记了模组数、没有一种物料设了 V9、没有隔离库位、没有通道分配、没有放电结果、没有拆分;require_calibrated_since 为 NULL。
--   ③ PROC-2026-0494 与那两条开着的状态逐行印出来(Q16:不回填、不碰)。
--   跑法:PGOPTIONS='-c default_transaction_read_only=on' psql "<pooler dsn>" -X -A -f 本文件(迁移前一次、全部验证之后一次)。
\pset pager off
\pset format unaligned
BEGIN READ ONLY;
SELECT 'identity', current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user), current_setting('transaction_read_only'),
       (now() AT TIME ZONE 'Asia/Singapore')::text;
SELECT 'stable', t, n, left(d, 12) FROM (
    SELECT 'inbound_batches (minus module_count)' AS t, count(*) AS n,
           md5(COALESCE(string_agg((to_jsonb(x) - 'module_count')::text, '|' ORDER BY x.id), '')) AS d FROM inbound_batches x
    UNION ALL SELECT 'output_batches (minus module_count)', count(*),
           md5(COALESCE(string_agg((to_jsonb(x) - 'module_count')::text, '|' ORDER BY x.id), '')) FROM output_batches x
    UNION ALL SELECT 'materials (minus V9)', count(*),
           md5(COALESCE(string_agg((to_jsonb(x) - 'discharge_pass_voltage_v')::text, '|' ORDER BY x.id), '')) FROM materials x
    UNION ALL SELECT 'operation_types (pre-existing rows, minus 2 flags)', count(*),
           md5(COALESCE(string_agg((to_jsonb(x) - 'verifies_by_unit' - 'started_from_run_page')::text, '|' ORDER BY x.code), '')) FROM operation_types x
           WHERE x.code <> 'discharge_quarantine_split'
    UNION ALL SELECT 'operation_type_safety_states (pre-existing rows)', count(*),
           md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x.operation_type_code, x.safety_state_code), '')) FROM operation_type_safety_states x
           WHERE x.operation_type_code <> 'discharge_quarantine_split'
    UNION ALL SELECT 'operation_type_input_forms (pre-existing rows)', count(*),
           md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x.operation_type_code, x.form_code), '')) FROM operation_type_input_forms x
           WHERE x.operation_type_code <> 'discharge_quarantine_split'
    UNION ALL SELECT 'operation_type_output_forms (pre-existing rows)', count(*),
           md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x.operation_type_code, x.form_code), '')) FROM operation_type_output_forms x
           WHERE x.operation_type_code <> 'discharge_quarantine_split'
    UNION ALL SELECT 'document_relation_exceptions (pre-existing rows)', count(*),
           md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x::text), '')) FROM document_relation_exceptions x
           WHERE to_jsonb(x)::text NOT LIKE '%discharge_module_splits%'
    UNION ALL SELECT 'processing_runs', count(*), md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '')) FROM processing_runs x
    UNION ALL SELECT 'processing_inputs', count(*), md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '')) FROM processing_inputs x
    UNION ALL SELECT 'processing_outputs', count(*), md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '')) FROM processing_outputs x
    UNION ALL SELECT 'inbound_batch_safety_states', count(*), md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x::text), '')) FROM inbound_batch_safety_states x
    UNION ALL SELECT 'output_batch_safety_states', count(*), md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x::text), '')) FROM output_batch_safety_states x
    UNION ALL SELECT 'inventory_movements', count(*), md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x::text), '')) FROM inventory_movements x
    UNION ALL SELECT 'storage_locations', count(*), md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '')) FROM storage_locations x
    UNION ALL SELECT 'devices', count(*), md5(COALESCE(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id), '')) FROM devices x
) s ORDER BY t;
-- ② 线上只设了点名的那两样
SELECT 'set', 'verifies_by_unit operations', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.operation_types'::regclass AND attname = 'verifies_by_unit')
        THEN 'SELECT COALESCE(string_agg(code, '','' ORDER BY code), ''(none)'') AS n FROM operation_types WHERE verifies_by_unit' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?');
SELECT 'set', 'started_from_run_page operations', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.operation_types'::regclass AND attname = 'started_from_run_page')
        THEN 'SELECT COALESCE(string_agg(code, '','' ORDER BY code), ''(none)'') AS n FROM operation_types WHERE started_from_run_page' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?');
SELECT 'set', 'split operation row', COALESCE((SELECT code || ' · ' || kind_code || ' · active=' || is_active || ' · sort ' || sort_order FROM operation_types WHERE code = 'discharge_quarantine_split'), '(absent)');
SELECT 'set', 'split operation states / input forms / output forms',
       (SELECT count(*) FROM operation_type_safety_states WHERE operation_type_code = 'discharge_quarantine_split') || ' / '
       || (SELECT count(*) FROM operation_type_input_forms WHERE operation_type_code = 'discharge_quarantine_split') || ' / '
       || (SELECT count(*) FROM operation_type_output_forms WHERE operation_type_code = 'discharge_quarantine_split');
SELECT 'set', 'relation exceptions on discharge_module_splits', (SELECT count(*) FROM document_relation_exceptions x WHERE to_jsonb(x)::text LIKE '%discharge_module_splits%');
SELECT 'set', 'batches with a module count', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.inbound_batches'::regclass AND attname = 'module_count')
        THEN 'SELECT (SELECT count(*) FROM inbound_batches WHERE module_count IS NOT NULL) + (SELECT count(*) FROM output_batches WHERE module_count IS NOT NULL) AS n'
        ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?');
SELECT 'set', 'materials with V9', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.materials'::regclass AND attname = 'discharge_pass_voltage_v')
        THEN 'SELECT count(*) AS n FROM materials WHERE discharge_pass_voltage_v IS NOT NULL' ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?');
SELECT 'set', 'quarantine locations', (SELECT count(*) FROM storage_locations WHERE is_quarantine);
SELECT 'set', 'discharge results / channel assignments / splits', COALESCE((xpath('/row/n/text()', query_to_xml(CASE WHEN to_regclass('public.discharge_module_results') IS NOT NULL
        THEN 'SELECT (SELECT count(*) FROM discharge_module_results) || '' / '' || (SELECT count(*) FROM discharge_channel_assignments) || '' / '' || (SELECT count(*) FROM discharge_module_splits) AS n'
        ELSE 'SELECT ''n/a'' AS n' END, false, true, '')))[1]::text, '?');
SELECT 'set', 'require_calibrated_since', COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL');
SELECT 'set', 'sequences output/inbound/processing', (SELECT last_value FROM output_code_seq) || ' / ' || (SELECT last_value FROM inbound_code_seq)
       || ' / ' || COALESCE((SELECT max(code) FROM processing_runs), '-');
-- ③ 不回填、不碰
SELECT 'proc0494', code, status, operation_type_code, COALESCE(deleted_at::text, '-'), process_date FROM processing_runs WHERE code = 'PROC-2026-0494';
SELECT 'open_state', 'inbound', b.code, s.safety_state_code, s.created_at, COALESCE(s.created_by_run_id::text, '-')
  FROM inbound_batch_safety_states s JOIN inbound_batches b ON b.id = s.inbound_batch_id
 WHERE s.ended_at IS NULL AND s.safety_state_code IN ('discharged_verified', 'charged_not_discharged')
UNION ALL
SELECT 'open_state', 'output', b.code, s.safety_state_code, s.created_at, COALESCE(s.created_by_run_id::text, '-')
  FROM output_batch_safety_states s JOIN output_batches b ON b.id = s.output_batch_id
 WHERE s.ended_at IS NULL AND s.safety_state_code IN ('discharged_verified', 'charged_not_discharged')
ORDER BY 1, 2, 3;
ROLLBACK;
