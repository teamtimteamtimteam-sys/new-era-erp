-- db/functions/discharge_result_internal.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23 · Q25;MES-5a Step 0 Q3–Q9 · Q12,Tim):【一条放电模组结果的判据与落库】—— 记与更正共用这一份。
--   内层:不是 DEFINER,authenticated 调不到(只经 record_discharge_module_result / correct_discharge_module_result)。
--   p_corrects_id 为空 = 记一条新的;不为空 = 更正那一条(那一炉、那一批、那个模组从原行来,不许换;理由必填)。
--   拒(按这个先后):
--     RUN_NOT_COMMITTED|<单>                          加工单没提交或已回滚
--     DISCHARGE_RUN_NOT_BY_UNIT|<单>|<工序>            这一炉的工序不按逐件结果核实(verifies_by_unit 为假)
--     BATCH_KIND_UNKNOWN|<种类> · DISCHARGE_BATCH_NOT_INPUT|<单>   这一批不是这一炉的投料
--     BATCH_MODULE_COUNT_REQUIRED|<批号>               这一批还没记模组数(Q4:记第一条结果之前必须有)
--     DISCHARGE_MODULE_REF_REQUIRED                    模组标识为空(或超过 60 个字)
--     DISCHARGE_MODULE_SPLIT_OUT|<模组>|<拆进的那一批>   这个模组已经被拆去隔离了 —— 它的结论记在那一批上
--     DISCHARGE_RESULT_ALREADY_RECORDED|<模组>|<单>     这一炉已经记过这个模组(要改就更正那一条)
--     DISCHARGE_MODULES_EXCEED_COUNT|<批号>|<模组数>     又一个新模组会超过这一批的模组数(Q6)
--     DISCHARGE_VERDICT_UNKNOWN|<判定> · DISCHARGE_DISPOSITION_REQUIRED|<模组>(判失败必须说再放电还是隔离)·
--     DISCHARGE_DISPOSITION_ON_PASS|<模组> · DISCHARGE_DISPOSITION_UNKNOWN|<处置>
--     DISCHARGE_VOLTAGE_INVALID                        出口电压为空或为负
--     DISCHARGE_VERDICT_AT_REQUIRED · DISCHARGE_VERDICT_IN_FUTURE · DISCHARGE_VERDICT_BEFORE_RUN|<单>
--     DISCHARGE_VALUE_INVALID|<字段>                    起始电压 / 时长 / 回收能量为负,或通道号不是正数
--     DISCHARGE_CHANNEL_MODULE_MISMATCH|<通道>|<当前记着的模组>   这一炉这个通道当前记着另一个模组
--     DISCHARGE_DEVICE_INVALID|<设备>                   给了设备却不是一台没停用的放电柜
--     更正:DISCHARGE_RESULT_NOT_FOUND|<id> · DISCHARGE_RESULT_SUPERSEDED|<id>(已被更正过 —— 更正链的末端)·
--           DISCHARGE_CORRECTION_REASON_REQUIRED · DISCHARGE_CORRECTION_SAME_VALUE(什么都没改)
--   V9(这一批物料的 discharge_pass_voltage_v)此刻的值抄进 pass_voltage_v_at;矛盾只标出(生成列),从不拒。来源 = manual。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.discharge_result_internal(p_run_id uuid, p_kind text, p_batch_id uuid, p_module_ref text, p_outlet_voltage_v numeric, p_verdict text, p_verdict_at timestamp with time zone, p_disposition text, p_channel_no integer, p_start_voltage_v numeric, p_duration_min numeric, p_energy_recovered_wh numeric, p_device_id uuid, p_photo_path text, p_notes text, p_corrects_id bigint, p_correction_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig     discharge_module_results%ROWTYPE;
    v_run      processing_runs%ROWTYPE;
    v_by_unit  boolean;
    v_kind     text := p_kind;
    v_batch    uuid := p_batch_id;
    v_ref      text := NULLIF(btrim(COALESCE(p_module_ref, '')), '');
    v_code     text;
    v_count    integer;
    v_material uuid;
    v_pass     numeric;
    v_cur      record;
    v_n        bigint;
    v_assigned text;
    v_disp     text := NULLIF(btrim(COALESCE(p_disposition, '')), '');
    v_id       bigint;
BEGIN
    IF p_corrects_id IS NOT NULL THEN
        SELECT * INTO v_orig FROM discharge_module_results WHERE id = p_corrects_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'DISCHARGE_RESULT_NOT_FOUND|%', p_corrects_id;
        END IF;
        IF EXISTS (SELECT 1 FROM discharge_module_results x WHERE x.corrects_id = p_corrects_id) THEN
            RAISE EXCEPTION 'DISCHARGE_RESULT_SUPERSEDED|%', p_corrects_id
              USING HINT = '这一条已经被更正过 —— 要再改,改链的末端那一条。';
        END IF;
        IF NULLIF(btrim(COALESCE(p_correction_reason, '')), '') IS NULL THEN
            RAISE EXCEPTION 'DISCHARGE_CORRECTION_REASON_REQUIRED';
        END IF;
        v_kind := CASE WHEN v_orig.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END;
        v_batch := COALESCE(v_orig.inbound_batch_id, v_orig.output_batch_id);
        v_ref := v_orig.module_ref;
    END IF;

    SELECT * INTO v_run FROM processing_runs WHERE id = COALESCE(v_orig.run_id, p_run_id);
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, COALESCE(p_run_id::text, '?'));
    END IF;
    SELECT ot.verifies_by_unit INTO v_by_unit FROM operation_types ot WHERE ot.code = v_run.operation_type_code;
    IF v_by_unit IS NOT TRUE THEN
        RAISE EXCEPTION 'DISCHARGE_RUN_NOT_BY_UNIT|%|%', v_run.code, COALESCE(v_run.operation_type_code, '?');
    END IF;

    IF v_kind = 'inbound' THEN
        SELECT b.code, b.module_count, b.material_id INTO v_code, v_count, v_material
          FROM inbound_batches b WHERE b.id = v_batch AND b.deleted_at IS NULL;
        IF NOT EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.run_id = v_run.id AND pi.inbound_batch_id = v_batch) THEN
            RAISE EXCEPTION 'DISCHARGE_BATCH_NOT_INPUT|%', v_run.code;
        END IF;
    ELSIF v_kind = 'output' THEN
        SELECT b.code, b.module_count, b.material_id INTO v_code, v_count, v_material
          FROM output_batches b WHERE b.id = v_batch AND b.deleted_at IS NULL;
        IF NOT EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.run_id = v_run.id AND pi.output_batch_id = v_batch) THEN
            RAISE EXCEPTION 'DISCHARGE_BATCH_NOT_INPUT|%', v_run.code;
        END IF;
    ELSE
        RAISE EXCEPTION 'BATCH_KIND_UNKNOWN|%', COALESCE(v_kind, '?');
    END IF;
    IF v_count IS NULL THEN
        RAISE EXCEPTION 'BATCH_MODULE_COUNT_REQUIRED|%', v_code
          USING HINT = '先在批次页上记下这一批有几个模组 —— 核实要每一个模组都有结论,没有总数就无从判"每一个"。';
    END IF;
    IF v_ref IS NULL OR length(v_ref) > 60 THEN
        RAISE EXCEPTION 'DISCHARGE_MODULE_REF_REQUIRED';
    END IF;

    SELECT * INTO v_cur FROM discharge_module_current_all c WHERE c.batch_id = v_batch AND c.module_ref = v_ref;
    IF FOUND AND v_cur.split_out THEN
        RAISE EXCEPTION 'DISCHARGE_MODULE_SPLIT_OUT|%|%', v_ref,
            COALESCE((SELECT ob.code FROM output_batches ob WHERE ob.id = v_cur.new_output_batch_id), '?');
    END IF;
    IF p_corrects_id IS NULL THEN
        IF EXISTS (SELECT 1 FROM discharge_module_results r
                    WHERE r.run_id = v_run.id AND COALESCE(r.inbound_batch_id, r.output_batch_id) = v_batch
                      AND r.module_ref = v_ref AND r.corrects_id IS NULL) THEN
            RAISE EXCEPTION 'DISCHARGE_RESULT_ALREADY_RECORDED|%|%', v_ref, v_run.code
              USING HINT = '这一炉已经记过这个模组 —— 要改,在那一条上更正(带理由)。再放一次电是另一炉。';
        END IF;
        IF v_cur.module_ref IS NULL THEN
            SELECT count(*) INTO v_n FROM discharge_module_current_all c WHERE c.batch_id = v_batch;
            IF v_n >= v_count THEN
                RAISE EXCEPTION 'DISCHARGE_MODULES_EXCEED_COUNT|%|%', v_code, v_count
                  USING HINT = '这一批记着这么多个模组,而它们都已经有结论了 —— 这一个是多出来的。模组数记错了就先在批次页上改它。';
            END IF;
        END IF;
    END IF;

    IF p_verdict IS NULL OR p_verdict NOT IN ('pass', 'fail') THEN
        RAISE EXCEPTION 'DISCHARGE_VERDICT_UNKNOWN|%', COALESCE(p_verdict, '?');
    END IF;
    IF p_verdict = 'fail' AND v_disp IS NULL THEN
        RAISE EXCEPTION 'DISCHARGE_DISPOSITION_REQUIRED|%', v_ref
          USING HINT = '一个没放完电的模组必须说出去处:再放一次电,或拆去隔离(规格 §3.1:两条路都要留下记录)。';
    END IF;
    IF p_verdict = 'pass' AND v_disp IS NOT NULL THEN
        RAISE EXCEPTION 'DISCHARGE_DISPOSITION_ON_PASS|%', v_ref;
    END IF;
    IF v_disp IS NOT NULL AND v_disp NOT IN ('re_discharge', 'quarantine') THEN
        RAISE EXCEPTION 'DISCHARGE_DISPOSITION_UNKNOWN|%', v_disp;
    END IF;
    IF p_outlet_voltage_v IS NULL OR p_outlet_voltage_v < 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VOLTAGE_INVALID';
    END IF;
    IF p_verdict_at IS NULL THEN
        RAISE EXCEPTION 'DISCHARGE_VERDICT_AT_REQUIRED';
    END IF;
    IF p_verdict_at > now() THEN
        RAISE EXCEPTION 'DISCHARGE_VERDICT_IN_FUTURE';
    END IF;
    IF v_run.started_at IS NOT NULL AND p_verdict_at < v_run.started_at THEN
        RAISE EXCEPTION 'DISCHARGE_VERDICT_BEFORE_RUN|%', v_run.code;
    END IF;
    IF p_start_voltage_v IS NOT NULL AND p_start_voltage_v < 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VALUE_INVALID|start_voltage_v';
    END IF;
    IF p_duration_min IS NOT NULL AND p_duration_min < 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VALUE_INVALID|duration_min';
    END IF;
    IF p_energy_recovered_wh IS NOT NULL AND p_energy_recovered_wh < 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VALUE_INVALID|energy_recovered_wh';
    END IF;
    IF p_channel_no IS NOT NULL AND p_channel_no <= 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VALUE_INVALID|channel_no';
    END IF;
    IF p_channel_no IS NOT NULL THEN
        SELECT a.module_ref INTO v_assigned
          FROM discharge_channel_assignments a
         WHERE a.run_id = v_run.id AND a.channel_no = p_channel_no AND NOT a.withdrawn
           AND NOT EXISTS (SELECT 1 FROM discharge_channel_assignments x WHERE x.corrects_id = a.id)
         ORDER BY a.id DESC LIMIT 1;
        IF v_assigned IS NOT NULL AND v_assigned <> v_ref THEN
            RAISE EXCEPTION 'DISCHARGE_CHANNEL_MODULE_MISMATCH|%|%', p_channel_no, v_assigned
              USING HINT = '这一炉这个通道记着另一个模组 —— 两份记录不能各说各话。先更正通道的分配,或改这一条的通道号。';
        END IF;
    END IF;
    IF p_device_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM devices d WHERE d.id = p_device_id AND d.retired_at IS NULL AND d.kind = 'discharge_cabinet') THEN
        RAISE EXCEPTION 'DISCHARGE_DEVICE_INVALID|%', p_device_id;
    END IF;

    IF p_corrects_id IS NOT NULL
       AND v_orig.outlet_voltage_v = p_outlet_voltage_v AND v_orig.verdict = p_verdict
       AND v_orig.verdict_at = p_verdict_at AND v_orig.disposition IS NOT DISTINCT FROM v_disp
       AND v_orig.channel_no IS NOT DISTINCT FROM p_channel_no AND v_orig.start_voltage_v IS NOT DISTINCT FROM p_start_voltage_v
       AND v_orig.duration_min IS NOT DISTINCT FROM p_duration_min AND v_orig.energy_recovered_wh IS NOT DISTINCT FROM p_energy_recovered_wh
       AND v_orig.device_id IS NOT DISTINCT FROM p_device_id
       AND v_orig.photo_path IS NOT DISTINCT FROM NULLIF(btrim(COALESCE(p_photo_path, '')), '')
       AND v_orig.notes IS NOT DISTINCT FROM NULLIF(btrim(COALESCE(p_notes, '')), '') THEN
        RAISE EXCEPTION 'DISCHARGE_CORRECTION_SAME_VALUE';
    END IF;

    SELECT m.discharge_pass_voltage_v INTO v_pass FROM materials m WHERE m.id = v_material;

    INSERT INTO discharge_module_results (run_id, inbound_batch_id, output_batch_id, module_ref, channel_no, outlet_voltage_v,
                                          start_voltage_v, verdict, verdict_at, disposition, duration_min, energy_recovered_wh,
                                          pass_voltage_v_at, photo_path, notes, source, device_id, corrects_id, correction_reason)
    VALUES (v_run.id,
            CASE WHEN v_kind = 'inbound' THEN v_batch END,
            CASE WHEN v_kind = 'output' THEN v_batch END,
            v_ref, p_channel_no, p_outlet_voltage_v, p_start_voltage_v, p_verdict, p_verdict_at, v_disp,
            p_duration_min, p_energy_recovered_wh, v_pass,
            NULLIF(btrim(COALESCE(p_photo_path, '')), ''), NULLIF(btrim(COALESCE(p_notes, '')), ''),
            'manual', p_device_id, p_corrects_id, NULLIF(btrim(COALESCE(p_correction_reason, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
