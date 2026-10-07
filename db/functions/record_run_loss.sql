-- db/functions/record_run_loss.sql
-- MES-4a(2026-10-07,规格 §4.1 · §4.2;MES-0 Q49;MES-4a Step 0 Q28,Tim):【给一炉记一条有名字的损耗】—— 只追加的那张表的两扇门之一。
--   此前页面直连 upsert 这张表;现在只经这里与 correct_run_loss。码与此前那三条写策略同一组:module.processing.edit 或
--   action.processing_aftercare(仓库 —— 提交加工的人记它的损耗,ROLE-1 Batch 3b Q2)。
--   加工单必须已提交、没回滚(RUN_NOT_COMMITTED);类别必须启用着(RUN_LOSS_CATEGORY_UNKNOWN);量为正(RUN_LOSS_QTY_INVALID);
--   这一类已经有一条(任何一条,哪怕撤回成 0)→ RUN_LOSS_ALREADY_RECORDED|<类别>(要改就更正它)。
--   有名字的损耗之和不许超过 loss_qty(= 投入 − 产出)—— 表上的约束触发器 LOSS_CATEGORIES_EXCEED_LOSS_QTY。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_run_loss(p_run_id uuid, p_loss_category_code text, p_quantity numeric, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run processing_runs%ROWTYPE;
    v_id  bigint;
BEGIN
    IF NOT has_any_permission(ARRAY['module.processing.edit', 'action.processing_aftercare']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.processing_aftercare';
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM loss_categories c WHERE c.code = p_loss_category_code AND c.is_active) THEN
        RAISE EXCEPTION 'RUN_LOSS_CATEGORY_UNKNOWN|%', COALESCE(p_loss_category_code, '?');
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'RUN_LOSS_QTY_INVALID|%', p_quantity;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_losses l WHERE l.run_id = p_run_id AND l.loss_category_code = p_loss_category_code) THEN
        RAISE EXCEPTION 'RUN_LOSS_ALREADY_RECORDED|%', p_loss_category_code;
    END IF;
    INSERT INTO processing_run_losses (run_id, loss_category_code, quantity, notes)
    VALUES (p_run_id, p_loss_category_code, p_quantity, NULLIF(btrim(COALESCE(p_notes, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
