-- db/functions/record_inspection_run.sql
-- MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q13 · Q14,Tim):【交一次巡检】—— 照一张启用的清单,每一项一个结果(pass · fail · na),
--   连同(可选的)发现,一次交完。module.safety.edit。没有审批(Q18)。
--   判的顺序就是人下一步该改什么的顺序:
--     ① 清单必填(INSPECTION_TEMPLATE_REQUIRED)· 巡检时刻必填(INSPECTION_TIME_REQUIRED —— 世界那一侧的事实,不给默认值)·
--        巡检的人必填(INSPECTION_INSPECTOR_REQUIRED)。
--     ② 清单存在(INSPECTION_TEMPLATE_NOT_FOUND|<id>)、启用着(INSPECTION_TEMPLATE_INACTIVE|<代号>)、至少一项(INSPECTION_TEMPLATE_HAS_NO_ITEMS|<代号>)。
--     ③ 巡检的人是一名在册员工(EMPLOYEE_NOT_FOUND)· 库位存在(LOCATION_NOT_FOUND)· 机器是一台在册的设备(equipment_record_target)。
--     ④ 更正(Q13):给了理由没给被更正的那一次 → INSPECTION_CORRECTION_NEEDS_RUN;给了那一次没给理由 → INSPECTION_CORRECTION_REASON_REQUIRED;
--        那一次找不到 → INSPECTION_RUN_NOT_FOUND|<id>;它已经被更正过 → INSPECTION_RUN_ALREADY_CORRECTED|<编号>(要再改,更正那一次更正)。
--     ⑤ 结果(p_results:[{position, result, note}]):清单上的每一项恰好一个 —— 不在清单上 INSPECTION_RESULT_UNKNOWN_ITEM|<项> ·
--        重复 INSPECTION_RESULT_DUPLICATE|<项> · 不是 pass / fail / na INSPECTION_RESULT_INVALID|<项>|<值> · 不合格没写说明
--        INSPECTION_FAIL_NOTE_REQUIRED|<项> · 少了一项 INSPECTION_RESULT_MISSING|<项>。
--   每一项的字从清单【抄】进结果,清单的代号 / 名字 / 片区抄进巡检 —— 之后改清单不改写这一次(Q13)。
--   发现(p_findings:[{position, corrective_action, owner_employee_id, due_date}])逐条走 record_inspection_finding(一份实现)。
--   表上的守卫再判【行】:时刻不在未来(INSPECTION_TIME_IN_FUTURE)。编号 INS-YYYY-NNNN(next_inspection_code,记录那一天的年)。
--   返回 {run_id, code, findings}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.record_inspection_run(p_template_id uuid, p_inspected_at timestamp with time zone, p_inspector_employee_id uuid, p_results jsonb, p_location_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text, p_findings jsonb DEFAULT NULL::jsonb, p_corrects_run_id uuid DEFAULT NULL::uuid, p_correction_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_id      uuid := gen_random_uuid();
    v_code    text;
    v_tpl     record;
    v_reason  text := NULLIF(btrim(COALESCE(p_correction_reason, '')), '');
    v_el      jsonb;
    v_pos     integer;
    v_res     text;
    v_note    text;
    v_seen    integer[] := ARRAY[]::integer[];
    v_missing integer;
    v_by      text;
    v_n       integer := 0;
BEGIN
    PERFORM require_permission('module.safety.edit');

    -- ① 必填
    IF p_template_id IS NULL THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_REQUIRED';
    END IF;
    IF p_inspected_at IS NULL THEN
        RAISE EXCEPTION 'INSPECTION_TIME_REQUIRED';
    END IF;
    IF p_inspector_employee_id IS NULL THEN
        RAISE EXCEPTION 'INSPECTION_INSPECTOR_REQUIRED';
    END IF;

    -- ② 清单
    SELECT t.id, t.code, t.name, t.area, t.is_active INTO v_tpl FROM inspection_templates t WHERE t.id = p_template_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_NOT_FOUND|%', p_template_id;
    END IF;
    IF NOT v_tpl.is_active THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_INACTIVE|%', v_tpl.code;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inspection_template_items i WHERE i.template_id = p_template_id) THEN
        RAISE EXCEPTION 'INSPECTION_TEMPLATE_HAS_NO_ITEMS|%', v_tpl.code;
    END IF;

    -- ③ 人、库位、机器
    IF NOT EXISTS (SELECT 1 FROM employees WHERE id = p_inspector_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_inspector_employee_id;
    END IF;
    IF p_location_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_location_id) THEN
        RAISE EXCEPTION 'LOCATION_NOT_FOUND|%', p_location_id;
    END IF;
    IF p_equipment_id IS NOT NULL THEN
        PERFORM equipment_record_target(p_equipment_id);
    END IF;

    -- ④ 更正
    IF p_corrects_run_id IS NULL AND v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'INSPECTION_CORRECTION_NEEDS_RUN';
    END IF;
    IF p_corrects_run_id IS NOT NULL THEN
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'INSPECTION_CORRECTION_REASON_REQUIRED';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM inspection_runs WHERE id = p_corrects_run_id) THEN
            RAISE EXCEPTION 'INSPECTION_RUN_NOT_FOUND|%', p_corrects_run_id;
        END IF;
        SELECT x.code INTO v_by FROM inspection_runs x WHERE x.corrects_run_id = p_corrects_run_id;
        IF v_by IS NOT NULL THEN
            RAISE EXCEPTION 'INSPECTION_RUN_ALREADY_CORRECTED|%', (SELECT code FROM inspection_runs WHERE id = p_corrects_run_id)
              USING HINT = '这一次巡检已经被 ' || v_by || ' 更正过 —— 要再改,就更正那一次。';
        END IF;
    END IF;

    -- ⑤ 结果:清单上的每一项恰好一个
    IF p_results IS NULL OR jsonb_typeof(p_results) <> 'array' OR jsonb_array_length(p_results) = 0 THEN
        RAISE EXCEPTION 'INSPECTION_RESULTS_REQUIRED';
    END IF;
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_results) LOOP
        v_pos := NULLIF(v_el ->> 'position', '')::integer;
        v_res := v_el ->> 'result';
        v_note := NULLIF(btrim(COALESCE(v_el ->> 'note', '')), '');
        IF v_pos IS NULL OR NOT EXISTS (SELECT 1 FROM inspection_template_items i WHERE i.template_id = p_template_id AND i.position = v_pos) THEN
            RAISE EXCEPTION 'INSPECTION_RESULT_UNKNOWN_ITEM|%', COALESCE(v_pos::text, '?');
        END IF;
        IF v_pos = ANY (v_seen) THEN
            RAISE EXCEPTION 'INSPECTION_RESULT_DUPLICATE|%', v_pos;
        END IF;
        v_seen := v_seen || v_pos;
        IF v_res IS NULL OR v_res NOT IN ('pass', 'fail', 'na') THEN
            RAISE EXCEPTION 'INSPECTION_RESULT_INVALID|%|%', v_pos, COALESCE(v_res, '?');
        END IF;
        IF v_res = 'fail' AND v_note IS NULL THEN
            RAISE EXCEPTION 'INSPECTION_FAIL_NOTE_REQUIRED|%', v_pos
              USING HINT = '一项不合格要写一句说明:哪里不对。';
        END IF;
    END LOOP;
    SELECT min(i.position) INTO v_missing FROM inspection_template_items i
     WHERE i.template_id = p_template_id AND NOT (i.position = ANY (v_seen));
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'INSPECTION_RESULT_MISSING|%', v_missing;
    END IF;

    v_code := next_inspection_code(CURRENT_DATE);
    INSERT INTO inspection_runs (id, code, template_id, template_code, template_name, template_area, inspected_at, inspector_employee_id,
                                 location_id, equipment_id, notes, corrects_run_id, correction_reason, recorded_by)
    VALUES (v_id, v_code, v_tpl.id, v_tpl.code, v_tpl.name, v_tpl.area, p_inspected_at, p_inspector_employee_id,
            p_location_id, p_equipment_id, NULLIF(btrim(COALESCE(p_notes, '')), ''), p_corrects_run_id, v_reason, v_user);
    INSERT INTO inspection_results (run_id, position, item_text, result, note)
    SELECT v_id, i.position, i.item_text, e ->> 'result', NULLIF(btrim(COALESCE(e ->> 'note', '')), '')
      FROM inspection_template_items i
      JOIN jsonb_array_elements(p_results) e ON (e ->> 'position')::integer = i.position
     WHERE i.template_id = p_template_id
     ORDER BY i.position;

    IF p_findings IS NOT NULL AND jsonb_typeof(p_findings) = 'array' THEN
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_findings) LOOP
            PERFORM record_inspection_finding(v_id, NULLIF(v_el ->> 'position', '')::integer, v_el ->> 'corrective_action',
                                              NULLIF(v_el ->> 'owner_employee_id', '')::uuid, NULLIF(v_el ->> 'due_date', '')::date);
            v_n := v_n + 1;
        END LOOP;
    END IF;
    RETURN jsonb_build_object('run_id', v_id, 'code', v_code, 'findings', v_n);
END;
$function$;
