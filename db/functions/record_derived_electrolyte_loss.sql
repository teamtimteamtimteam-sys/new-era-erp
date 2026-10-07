-- db/functions/record_derived_electrolyte_loss.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q51 · V10;MES-4b Step 0 Q16–Q20,Tim):【给一炉记一笔算出来的电解液挥发】。
--   量 = 这道工序的电解液份额(operation_types.electrolyte_share_pct,V10)× 这一炉的投入(total_input)/ 100,保留三位小数;
--   份额抄进那一行(derived_share_pct),basis = 'derived'。**从来不是余数**(投入 − 产出 − 别的损耗)—— 那会让每一炉按构造结平。
--   只在提交之后、由人在加工单页上按下去才记(从不在提交时自动算)。码:action.processing_aftercare(PERMISSION_DENIED|…)。
--   拒(按这个先后):加工单没提交 / 已回滚(RUN_NOT_COMMITTED)· 状态改变型的一炉(ELECTROLYTE_LOSS_STATE_CHANGING|<工序>)·
--   工序没勾「Electrolyte evaporates in this step」(ELECTROLYTE_LOSS_NOT_APPLICABLE|<工序>)· 份额没给(ELECTROLYTE_SHARE_NOT_SET|<工序>)·
--   这一类不许算(RUN_LOSS_NOT_DERIVABLE|<类别>)· 这一类已经有一条(RUN_LOSS_ALREADY_RECORDED|<类别> —— 要改就更正它)·
--   算出来是 0(RUN_LOSS_QTY_INVALID|0)· 有名字的损耗之和超过 投入 − 产出(表上的约束触发器 LOSS_CATEGORIES_EXCEED_LOSS_QTY)。
--   一炉结过平之后再记一笔 → 水位线被越过,那一炉回到"没结平"。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.record_derived_electrolyte_loss(p_run_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cat     constant text := 'electrolyte_evaporation';
    v_run     processing_runs%ROWTYPE;
    v_ot      operation_types%ROWTYPE;
    v_produce boolean;
    v_qty     numeric;
    v_id      bigint;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    SELECT * INTO v_ot FROM operation_types WHERE code = v_run.operation_type_code;
    SELECT k.produces_outputs INTO v_produce FROM operation_kinds k WHERE k.code = v_ot.kind_code;
    IF v_produce IS NOT TRUE THEN
        RAISE EXCEPTION 'ELECTROLYTE_LOSS_STATE_CHANGING|%', COALESCE(v_run.operation_type_code, '?')
          USING HINT = '状态改变型的一炉(放电)投入恒等于产出、损耗恒为 0 —— 没有电解液挥发可记。';
    END IF;
    IF NOT v_ot.electrolyte_loss_applies THEN
        RAISE EXCEPTION 'ELECTROLYTE_LOSS_NOT_APPLICABLE|%', v_ot.code
          USING HINT = '这道工序没有勾「Electrolyte evaporates in this step」。哪几段有电解液挥发,在工序页上勾。';
    END IF;
    IF v_ot.electrolyte_share_pct IS NULL THEN
        RAISE EXCEPTION 'ELECTROLYTE_SHARE_NOT_SET|%', v_ot.code
          USING HINT = '这道工序的电解液份额(V10)还没给 —— 没有份额就算不出来。可以改成量出来的,或先在工序页上给份额。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM loss_categories c WHERE c.code = v_cat AND c.is_active AND c.may_be_derived) THEN
        RAISE EXCEPTION 'RUN_LOSS_NOT_DERIVABLE|%', v_cat;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_losses l WHERE l.run_id = p_run_id AND l.loss_category_code = v_cat) THEN
        RAISE EXCEPTION 'RUN_LOSS_ALREADY_RECORDED|%', v_cat;
    END IF;
    v_qty := round(v_ot.electrolyte_share_pct * v_run.total_input / 100, 3);
    IF v_qty IS NULL OR v_qty <= 0 THEN
        RAISE EXCEPTION 'RUN_LOSS_QTY_INVALID|%', COALESCE(v_qty, 0);
    END IF;
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, notes, basis, derived_share_pct)
    VALUES (p_run_id, v_cat, v_qty, NULLIF(btrim(COALESCE(p_notes, '')), ''), 'derived', v_ot.electrolyte_share_pct)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$