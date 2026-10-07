-- db/functions/correct_run_loss.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q28,Tim):【更正一条有名字的损耗】—— 不改原行,落一条新的指回它。
--   码:module.processing.edit 或 action.processing_aftercare。理由必填(RUN_LOSS_CORRECTION_REASON_REQUIRED);只能更正链的末端
--   (RUN_LOSS_SUPERSEDED|<id>);新量不为负(RUN_LOSS_QTY_INVALID)—— 0 就是【撤回】这一类;与原值相同按名拒(RUN_LOSS_CORRECTION_SAME_VALUE)。
--   类别与加工单照抄原行。之和仍不许超过 loss_qty。之后结平的水位线被越过 → 那一炉回到"没结平"(Q19)。返回新行 id。
--   MES-4b(2026-10-07,Step 0 Q19):这扇门落的更正永远是【量出来的】(basis = 'measured')—— 一笔算出来的电解液挥发
--   改成量出来的就走这里;重新算走 rederive_electrolyte_loss。原行是算出来的时,与原值相同【不】拒:依据变了(量过了),那就是一次更正。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.correct_run_loss(p_loss_id bigint, p_quantity numeric, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run  processing_runs%ROWTYPE;
    v_orig processing_run_losses%ROWTYPE;
    v_id   bigint;
BEGIN
    IF NOT has_any_permission(ARRAY['module.processing.edit', 'action.processing_aftercare']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.processing_aftercare';
    END IF;
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
    IF p_quantity IS NULL OR p_quantity < 0 THEN
        RAISE EXCEPTION 'RUN_LOSS_QTY_INVALID|%', p_quantity;
    END IF;
    IF p_quantity = v_orig.quantity AND v_orig.basis = 'measured' THEN
        RAISE EXCEPTION 'RUN_LOSS_CORRECTION_SAME_VALUE';
    END IF;
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, notes, corrects_id, correction_reason, basis)
    VALUES (v_orig.run_id, v_orig.loss_category_code, p_quantity, v_orig.notes, v_orig.id, btrim(p_reason), 'measured')
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
