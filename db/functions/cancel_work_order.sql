CREATE OR REPLACE FUNCTION public.cancel_work_order(p_work_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_wo   work_orders%ROWTYPE;
    v_runs integer;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_CANCELLABLE|%|%', v_wo.code, v_wo.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CANCEL_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- 【已经开过工的单子不能取消 —— 它只能收工】取消的意思是"这件事没有发生过";
    -- 而挂着一条加工单,就意味着料真的下去了、产出真的进了库。把它标成 cancelled
    -- 会让那几次加工失去它们的出处,而出处是这套系统存在的理由。
    --
    -- 【只数没有被冲销的 —— 而这两个条件今天是【等价】的】
    -- 链接是历史,它断言过的消耗不是:一次被冲销的加工,料退回了、产出批作废了,
    -- 那次消耗不再是发生过的事实,所以它拦不住取消。
    -- rollback_processing_run 同时写 status='reversed' 与 deleted_at,所以单写
    -- deleted_at IS NULL 也能得到同一个结果 —— 两个条件都在这里,是因为它们的
    -- 等价【是一个巧合】:哪天有一条路径只写其中一列,它们就分开了,而那时没有
    -- 任何东西会喊。把隐含的巧合写成显式的判据。
    -- (WO-1b 一度把这写成"修掉了 WO-1a 的一个 bug" —— 那句话是错的,
    --  见 db/migrations/2026-08-16-wo1b-fu1-*.sql。)
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL AND status = 'committed';
    IF v_runs > 0 THEN
        RAISE EXCEPTION 'WO_HAS_RUNS|%|%', v_wo.code, v_runs;
    END IF;

    UPDATE work_orders
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_user,
           cancel_reason = btrim(p_reason), updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, amend_reason, changed_by)
    VALUES (p_work_order_id, 'cancelled', btrim(p_reason), v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code, 'status', 'cancelled');
END;
$function$

;
