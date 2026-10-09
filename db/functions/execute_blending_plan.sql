-- db/functions/execute_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q18 · Q19,Tim):【执行一份已放行的配料计划 —— 从计划页上,记一炉 blending】
--   码:action.processing_commit(Q19;提交一炉本来就要它,引擎自己再判一次)。只执行 released(BLEND_PLAN_NOT_RELEASED|<编号>|<状态>)。
--   ★ 这是 commit_processing_run 的一层外壳 —— MES-5a-1 拆去隔离的先例:引擎的签名【一个字不改】。
--     ① 每一行实际投了多少(p_actual = [{line_id, actual_kg}]):这份计划的每一行恰好一次(BLEND_ACTUAL_LINES_MISMATCH),
--        ≥ 0(BLEND_ACTUAL_KG_INVALID|<批号>);0 = 这一批这次没用上(不进投料腿);至少一行 > 0(BLEND_ACTUAL_NOTHING_FED)。
--        实际与计划可以不同(Q18)—— 差多少由 blending_plan_execution 照直印出来,不拒。
--     ② 混出来的那一批:产出物料 = 计划的产出物料,重量敲一个(p_weight_kg)或挑一条称重(p_weighing_id)—— 引擎照旧判称重、
--        开始 / 结束 / 班次、余量、安全状态(配料只收"已放电并核验")与"产出不多于投入"。
--     ③ 设事务级标记 evoltrya.blend_ctx = 这份计划,调引擎,用毕即清 —— processing_runs 上的守卫(guard_blending_run_from_plan)
--        因此只放行从这里记的 blending,别的任何路(新建加工单的表单、直接调引擎)按名拒 BLEND_RUN_FROM_PLAN_ONLY。
--     ④ 计划改成 executed,记下那一炉。
--   【含量不从预测写】(Q18):混出来那一批一行金属含量都不写 —— 它的含量只来自之后的化验(guard_blended_batch_metals_from_assay)。
--   返回 {plan_id, code, run_id, run_code, batch_id, batch_code, input_kg, output_kg}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.execute_blending_plan(p_plan_id uuid, p_process_date date, p_started_at timestamp with time zone, p_ended_at timestamp with time zone, p_shift_code text, p_actual jsonb, p_weight_kg numeric DEFAULT NULL::numeric, p_weighing_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_plan    blending_plans%ROWTYPE;
    v_line    record;
    v_el      jsonb;
    v_kg      numeric;
    v_inputs  jsonb := '[]'::jsonb;
    v_seen    uuid[] := ARRAY[]::uuid[];
    v_n       integer;
    v_run     uuid;
    v_batch   uuid;
    v_bcode   text;
BEGIN
    PERFORM require_permission('action.processing_commit');
    SELECT * INTO v_plan FROM blending_plans WHERE id = p_plan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_FOUND|%', COALESCE(p_plan_id::text, '?');
    END IF;
    IF v_plan.status <> 'released' THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_RELEASED|%|%', v_plan.code, v_plan.status
          USING HINT = '只有放行过的计划执行得了:草稿先请另一个人放行;已执行或已取消的不能再执行。';
    END IF;

    -- ① 实际投料:这份计划的每一行恰好一次
    IF p_actual IS NULL OR jsonb_typeof(p_actual) <> 'array' THEN
        RAISE EXCEPTION 'BLEND_ACTUAL_LINES_MISMATCH|%', v_plan.code;
    END IF;
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_actual) LOOP
        SELECT l.*, COALESCE(ib.code, ob.code) AS batch_code INTO v_line
          FROM blending_plan_lines l
          LEFT JOIN inbound_batches ib ON ib.id = l.inbound_batch_id
          LEFT JOIN output_batches ob ON ob.id = l.output_batch_id
         WHERE l.plan_id = p_plan_id AND l.id = NULLIF(v_el ->> 'line_id', '')::uuid;
        IF NOT FOUND OR v_line.id = ANY (v_seen) THEN
            RAISE EXCEPTION 'BLEND_ACTUAL_LINES_MISMATCH|%', v_plan.code
              USING HINT = '每一行计划都要说出这次实际投了多少(没用上就写 0),一行一次。';
        END IF;
        v_seen := v_seen || v_line.id;
        v_kg := NULLIF(v_el ->> 'actual_kg', '')::numeric;
        IF v_kg IS NULL OR v_kg < 0 THEN
            RAISE EXCEPTION 'BLEND_ACTUAL_KG_INVALID|%', v_line.batch_code;
        END IF;
        IF v_kg > 0 THEN
            v_inputs := v_inputs || jsonb_build_array(CASE WHEN v_line.inbound_batch_id IS NOT NULL
                THEN jsonb_build_object('inbound_batch_id', v_line.inbound_batch_id, 'quantity_consumed', v_kg)
                ELSE jsonb_build_object('output_batch_id', v_line.output_batch_id, 'quantity_consumed', v_kg) END);
        END IF;
    END LOOP;
    SELECT count(*) INTO v_n FROM blending_plan_lines l WHERE l.plan_id = p_plan_id;
    IF cardinality(v_seen) <> v_n THEN
        RAISE EXCEPTION 'BLEND_ACTUAL_LINES_MISMATCH|%', v_plan.code;
    END IF;
    IF jsonb_array_length(v_inputs) = 0 THEN
        RAISE EXCEPTION 'BLEND_ACTUAL_NOTHING_FED|%', v_plan.code;
    END IF;

    -- ②③ 经引擎记一炉 blending(标记只在这一句的前后存在)
    PERFORM set_config('evoltrya.blend_ctx', p_plan_id::text, true);
    v_run := commit_processing_run(
        p_process_date,
        COALESCE(NULLIF(btrim(COALESCE(p_notes, '')), ''), 'Blending plan ' || v_plan.code),
        NULL,
        v_inputs,
        jsonb_build_array(CASE WHEN p_weighing_id IS NOT NULL
                               THEN jsonb_build_object('material_id', v_plan.output_material_id, 'weighing_id', p_weighing_id)
                               ELSE jsonb_build_object('material_id', v_plan.output_material_id, 'weight_kg', p_weight_kg) END),
        'weight', NULL, NULL, 'blending', p_started_at, p_ended_at, p_shift_code, NULL, NULL, NULL);
    PERFORM set_config('evoltrya.blend_ctx', '', true);

    SELECT po.output_batch_id, ob.code INTO v_batch, v_bcode
      FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = v_run;

    -- ④ 计划记下那一炉
    UPDATE blending_plans
       SET status = 'executed', executed_at = now(), executed_by = v_user, run_id = v_run, updated_at = now(), updated_by = v_user
     WHERE id = p_plan_id;

    RETURN jsonb_build_object('plan_id', p_plan_id, 'code', v_plan.code, 'run_id', v_run,
                              'run_code', (SELECT r.code FROM processing_runs r WHERE r.id = v_run),
                              'batch_id', v_batch, 'batch_code', v_bcode,
                              'input_kg', (SELECT r.total_input FROM processing_runs r WHERE r.id = v_run),
                              'output_kg', (SELECT r.total_output FROM processing_runs r WHERE r.id = v_run));
END;
$function$
