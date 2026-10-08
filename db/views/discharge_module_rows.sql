-- db/views/discharge_module_rows.sql
-- MES-5a-1(2026-10-08,MES-5a Step 0 Q7 · Q13,Tim):【一条一条的放电模组结果,带上它的那一炉与那一批】—— 带门的属主视图。
--   放电那一炉的页面(模组结果面板)与两种批次页读它。门:加工、进料或产出查看码任一(与三张放电表的读规则同一个)。
--   【为什么是属主视图】只持进料或产出码的人读不到 processing_runs(加工码),一张 invoker 视图把它们 join 起来会安静地丢掉每一行
--   (AGENTS.md 的 xmodule)。借过去的只有那一炉的单号、加工日与是否回滚 —— 一个显示标签与它本来就挂着的事实。
--   is_current:没有被别的行更正过、那一炉没回滚;is_latest:这个模组此刻的结论就是这一条(discharge_module_current_all);
--   split_out:这个模组被拆去隔离了。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE VIEW public.discharge_module_rows WITH (security_invoker = off) AS
 SELECT d.id,
    d.run_id,
    r.code AS run_code,
    r.process_date,
    r.status AS run_status,
        CASE
            WHEN d.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(d.inbound_batch_id, d.output_batch_id) AS batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    d.module_ref,
    d.channel_no,
    d.outlet_voltage_v,
    d.start_voltage_v,
    d.verdict,
    d.verdict_at,
    d.disposition,
    d.duration_min,
    d.energy_recovered_wh,
    d.pass_voltage_v_at,
    d.contradicts_pass_voltage,
    d.photo_path,
    d.notes,
    d.source,
    d.device_id,
    d.recorded_at,
    d.recorded_by,
    d.corrects_id,
    d.correction_reason,
    r.status = 'committed'::text AND r.deleted_at IS NULL AND NOT (EXISTS ( SELECT 1
           FROM discharge_module_results x
          WHERE x.corrects_id = d.id)) AS is_current,
    (EXISTS ( SELECT 1
           FROM discharge_module_current_all c
          WHERE c.result_id = d.id)) AS is_latest,
    COALESCE(( SELECT c.split_out
           FROM discharge_module_current_all c
          WHERE c.batch_id = COALESCE(d.inbound_batch_id, d.output_batch_id) AND c.module_ref = d.module_ref), false) AS split_out
   FROM discharge_module_results d
     JOIN processing_runs r ON r.id = d.run_id
     LEFT JOIN inbound_batches ib ON ib.id = d.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = d.output_batch_id
  WHERE has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]);

COMMENT ON VIEW public.discharge_module_rows IS
    'MES-5a-1:放电模组结果逐条,带那一炉的单号 / 加工日 / 状态与那一批的批号;is_current = 链的末端且那一炉没回滚,is_latest = 这个模组此刻的结论,split_out = 已拆去隔离。带门(加工、进料或产出查看码)的属主视图。';

GRANT SELECT ON public.discharge_module_rows TO authenticated;
REVOKE ALL ON public.discharge_module_rows FROM anon;
