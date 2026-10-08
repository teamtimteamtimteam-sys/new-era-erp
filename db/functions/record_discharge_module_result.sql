-- db/functions/record_discharge_module_result.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q25;MES-5a Step 0 Q7 · Q10,Tim):【记一个模组这一炉的放电结果】—— 手工录入(来源 manual)。
--   码:action.confirm_capture(采集那条管道的码 —— 现场的人读放电柜的屏幕记下来;MES-5a Step 0 Q10)。
--   判据都在 discharge_result_internal;记下之后照规则重判这一批(discharge_verify_batch:凑满了就改成已放电并核实,记下是这一炉)。
--   【为什么不经 submit_manual_capture】那条手工路要跑这一类的转换器,而 discharge_module 的转换器【没有建】—— Bosch 的逐模组导出
--   格式没人给过,照着一个编出来的格式建就是 MES-3b Q25 / MES-4a Q14 说的那件事。所以照 MES-4a 记参数的先例:直接记,source = manual,
--   收件箱 / 草稿 / 现场数据那几列留空;将来接上设备,那几列已经在,不必改表。
--   返回 {id, batch_code, verified}。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.record_discharge_module_result(p_run_id uuid, p_kind text, p_batch_id uuid, p_module_ref text, p_outlet_voltage_v numeric, p_verdict text, p_verdict_at timestamp with time zone, p_disposition text DEFAULT NULL::text, p_channel_no integer DEFAULT NULL::integer, p_start_voltage_v numeric DEFAULT NULL::numeric, p_duration_min numeric DEFAULT NULL::numeric, p_energy_recovered_wh numeric DEFAULT NULL::numeric, p_device_id uuid DEFAULT NULL::uuid, p_photo_path text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id  bigint;
    v_ok  boolean;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    v_id := discharge_result_internal(p_run_id, p_kind, p_batch_id, p_module_ref, p_outlet_voltage_v, p_verdict, p_verdict_at,
                                      p_disposition, p_channel_no, p_start_voltage_v, p_duration_min, p_energy_recovered_wh,
                                      p_device_id, p_photo_path, p_notes, NULL, NULL);
    v_ok := discharge_verify_batch(p_kind, p_batch_id, p_run_id, NULL);
    RETURN jsonb_build_object('id', v_id, 'verified', v_ok,
        'batch_code', COALESCE((SELECT b.code FROM inbound_batches b WHERE b.id = p_batch_id),
                               (SELECT b.code FROM output_batches b WHERE b.id = p_batch_id)));
END;
$function$
