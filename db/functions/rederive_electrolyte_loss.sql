-- db/functions/rederive_electrolyte_loss.sql
-- MES-4b(2026-10-07,MES-0 Q51;MES-4b Step 0 Q19,Tim):【按现在的份额重新算一笔电解液挥发】—— 更正的一种(另一种是改成量出来的:correct_run_loss)。
--   不改原行:落一条新行指回它(corrects_id)+ 必填理由,basis = 'derived',份额照【此刻】的工序设置抄下。
--   码:action.processing_aftercare。拒:找不到(RUN_LOSS_NOT_FOUND)· 加工单没提交 / 已回滚(RUN_NOT_COMMITTED)· 已被更正过(RUN_LOSS_SUPERSEDED)·
--   理由空(RUN_LOSS_CORRECTION_REASON_REQUIRED)· 这一类不许算(RUN_LOSS_NOT_DERIVABLE)· 状态改变型 / 没勾 / 份额没给(同 record_derived_electrolyte_loss)·
--   算出来与当前那一条完全相同(RUN_LOSS_CORRECTION_SAME_VALUE —— 量与依据都一样,没有东西可更正)· 算出来是 0(RUN_LOSS_QTY_INVALID)。
--   之和仍不许超过 投入 − 产出;结过平的一炉回到"没结平"。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.rederive_electrolyte_loss(p_loss_id bigint, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig    processing_run_losses%ROWTYPE;
    v_run     processing_runs%ROWTYPE;
    v_ot      operation_types%ROWTYPE;
    v_produce boolean;
    v_qty     numeric;
    v_id      bigint;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_orig FROM processing_run_losses WHERE id = p_loss_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_LOSS_NOT_FOUND|%', p_loss_id;
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = v_orig.run_id FOR UPDATE;
    IF v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.code;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_losses x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'RUN_LOSS_SUPERSEDED|%', v_orig.id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'RUN_LOSS_CORRECTION_REASON_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM loss_categories c WHERE c.code = v_orig.loss_category_code AND c.may_be_derived) THEN
        RAISE EXCEPTION 'RUN_LOSS_NOT_DERIVABLE|%', v_orig.loss_category_code;
    END IF;
    SELECT * INTO v_ot FROM operation_types WHERE code = v_run.operation_type_code;
    SELECT k.produces_outputs INTO v_produce FROM operation_kinds k WHERE k.code = v_ot.kind_code;
    IF v_produce IS NOT TRUE THEN
        RAISE EXCEPTION 'ELECTROLYTE_LOSS_STATE_CHANGING|%', COALESCE(v_run.operation_type_code, '?');
    END IF;
    IF NOT v_ot.electrolyte_loss_applies THEN
        RAISE EXCEPTION 'ELECTROLYTE_LOSS_NOT_APPLICABLE|%', v_ot.code;
    END IF;
    IF v_ot.electrolyte_share_pct IS NULL THEN
        RAISE EXCEPTION 'ELECTROLYTE_SHARE_NOT_SET|%', v_ot.code;
    END IF;
    v_qty := round(v_ot.electrolyte_share_pct * v_run.total_input / 100, 3);
    IF v_qty IS NULL OR v_qty <= 0 THEN
        RAISE EXCEPTION 'RUN_LOSS_QTY_INVALID|%', COALESCE(v_qty, 0);
    END IF;
    IF v_orig.basis = 'derived' AND v_qty = v_orig.quantity AND v_ot.electrolyte_share_pct = v_orig.derived_share_pct THEN
        RAISE EXCEPTION 'RUN_LOSS_CORRECTION_SAME_VALUE';
    END IF;
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, notes, corrects_id, correction_reason, basis, derived_share_pct)
    VALUES (v_orig.run_id, v_orig.loss_category_code, v_qty, v_orig.notes, v_orig.id, btrim(p_reason), 'derived', v_ot.electrolyte_share_pct)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$