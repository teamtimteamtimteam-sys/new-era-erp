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
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL;
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
