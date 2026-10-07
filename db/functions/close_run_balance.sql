-- db/functions/close_run_balance.sql
-- MES-4a(2026-10-07,规格 §4.1;MES-0 Q46 · Q47 · Q50;MES-4a Step 0 Q19–Q21,Tim):【结平一炉的物料平衡】。
--   持 action.processing_aftercare(Q50 —— 记损耗的那个码;不要第二个人,Q47)。算术读 processing_run_balance_all(一份算术)。
--   按顺序拒:
--     RUN_NOT_COMMITTED|<单>             已回滚 / 已删
--     RUN_BALANCE_NOT_APPLICABLE|<单>    状态改变型(放电):投入恒等于产出,没有平衡可结(Q20)
--     RUN_BALANCE_BEFORE_CLOSURE|<单>    MES-4a 之前记下的单(开始时刻为空):不能结(Q21)
--     RUN_BALANCE_ALREADY_CLOSED|<单>    最新一次结平还是当前的
--     RUN_REQUIRED_VALUES_MISSING|<单>|<字段,…>   必填的参数 / 指标缺着(必填在这里判,不在提交时,Q11)
--     RUN_OUTPUT_WEIGHING_MISSING|<单>|<条数>      有产出腿没挂称重(Q22)
--     RUN_BALANCE_EXPLANATION_REQUIRED|<单>|<余数>|<容差 或 not_set>
--         余数不为 0,而容差没给(Q46)或超出了给的容差(Q47)→ 要一句书面说明。余数为 0、或在给了的容差里 → 说明可选。
--   落一行 processing_run_closures:那一刻的账、容差与判断、说明、损耗与值的 id 水位线。返回它的 id。
--   之后再有损耗或值被记下或更正 → 水位线被越过 → 这次结平不再当前(重开,不改任何一行)。
--   【与成本无关,两个方向都是】分摊不读损耗,结平不动钱;分摊也不等结平(Q23)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.close_run_balance(p_run_id uuid, p_explanation text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    b      record;
    v_expl text := NULLIF(btrim(COALESCE(p_explanation, '')), '');
    v_id   bigint;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT r.code INTO v_code FROM processing_runs r WHERE r.id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    SELECT * INTO b FROM processing_run_balance_all WHERE run_id = p_run_id;
    IF b.balance_state = 'reversed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_code;
    END IF;
    IF b.balance_state = 'not_applicable' THEN
        RAISE EXCEPTION 'RUN_BALANCE_NOT_APPLICABLE|%', v_code
          USING HINT = '状态改变型工序(放电)同一批进、同一批出 —— 投入恒等于产出,损耗恒为 0,没有平衡可结。';
    END IF;
    IF b.balance_state = 'before_closure' THEN
        RAISE EXCEPTION 'RUN_BALANCE_BEFORE_CLOSURE|%', v_code
          USING HINT = '这张单记在结平之前(没有开始时刻、产出没有称重):不能结,也不回填。';
    END IF;
    IF b.balance_state = 'closed' THEN
        RAISE EXCEPTION 'RUN_BALANCE_ALREADY_CLOSED|%', v_code;
    END IF;
    IF cardinality(b.required_missing) > 0 THEN
        RAISE EXCEPTION 'RUN_REQUIRED_VALUES_MISSING|%|%', v_code, array_to_string(b.required_missing, ',')
          USING HINT = '这道工序上必填的参数或指标还缺着 —— 先在加工单页上记下来再结。';
    END IF;
    IF b.outputs_unweighed > 0 THEN
        RAISE EXCEPTION 'RUN_OUTPUT_WEIGHING_MISSING|%|%', v_code, b.outputs_unweighed;
    END IF;
    IF b.remainder_qty <> 0 AND b.within_tolerance IS NOT TRUE AND v_expl IS NULL THEN
        RAISE EXCEPTION 'RUN_BALANCE_EXPLANATION_REQUIRED|%|%|%', v_code, b.remainder_qty, COALESCE(b.tolerance_pct::text, 'not_set')
          USING HINT = '投入不等于产出加有名字的损耗,而余数不在一个给了的容差里(或容差还没给)—— 写一句说明这一截去了哪里。';
    END IF;
    INSERT INTO processing_run_closures (run_id, input_qty, output_qty, named_loss_qty, remainder_qty, tolerance_pct, within_tolerance,
                                         explanation, loss_watermark, value_watermark)
    VALUES (p_run_id, b.input_qty, b.output_qty, b.named_loss_qty, b.remainder_qty, b.tolerance_pct, b.within_tolerance,
            v_expl, b.max_loss_id, b.max_value_id)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
