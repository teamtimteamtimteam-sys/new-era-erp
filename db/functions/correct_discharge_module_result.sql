-- db/functions/correct_discharge_module_result.sql
-- MES-5a-1(2026-10-08,规格 §4.2 "process records are append-only";MES-5a Step 0 Q7,Tim):【更正一条放电模组结果】—— 新行指回原行,理由必填。
--   那一炉、那一批、那个模组从原行来,不许换;其余每一格都按这一次给的值重写(判据与记一条新的同一份,discharge_result_internal)。
--   码:action.confirm_capture。更正之后照规则重判这一批 —— 把一条通过改成失败,会让一批已经核实的料重新拦在火闸外(discharge_verify_batch)。
--   返回 {id, batch_code, verified}。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.correct_discharge_module_result(p_id bigint, p_outlet_voltage_v numeric, p_verdict text, p_verdict_at timestamp with time zone, p_disposition text, p_channel_no integer, p_start_voltage_v numeric, p_duration_min numeric, p_energy_recovered_wh numeric, p_device_id uuid, p_photo_path text, p_notes text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig  discharge_module_results%ROWTYPE;
    v_id    bigint;
    v_kind  text;
    v_batch uuid;
    v_ok    boolean;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    v_id := discharge_result_internal(NULL, NULL, NULL, NULL, p_outlet_voltage_v, p_verdict, p_verdict_at, p_disposition, p_channel_no,
                                      p_start_voltage_v, p_duration_min, p_energy_recovered_wh, p_device_id, p_photo_path, p_notes,
                                      p_id, p_reason);
    SELECT * INTO v_orig FROM discharge_module_results WHERE id = v_id;
    v_kind := CASE WHEN v_orig.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END;
    v_batch := COALESCE(v_orig.inbound_batch_id, v_orig.output_batch_id);
    v_ok := discharge_verify_batch(v_kind, v_batch, v_orig.run_id, 'result corrected: ' || btrim(p_reason));
    RETURN jsonb_build_object('id', v_id, 'verified', v_ok,
        'batch_code', COALESCE((SELECT b.code FROM inbound_batches b WHERE b.id = v_batch),
                               (SELECT b.code FROM output_batches b WHERE b.id = v_batch)));
END;
$function$
