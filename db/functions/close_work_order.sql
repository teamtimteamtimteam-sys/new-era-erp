CREATE OR REPLACE FUNCTION public.close_work_order(p_work_order_id uuid, p_reason text)
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
    IF v_wo.status <> 'released' THEN
        -- draft 的单子要"不做了",走 cancel —— 见上面那张迁移表的最后一段
        RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CLOSE_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- 【短交不拦 —— 这是一个决定,不是遗漏】实际做的比计划少,是一个要记下来的
    -- 事实。拦住它只会让人把计划改小以求关单,而那正好把差异从账上抹掉 ——
    -- 一条逼人去伪造数据的规则比没有规则更坏。收工时挂了几条加工单一并记进理由行,
    -- 让"关的时候是什么样"留在历史里,而不必事后重算。
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL;

    UPDATE work_orders
       SET status = 'closed', closed_at = now(), closed_by = v_user,
           close_reason = btrim(p_reason), updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, detail, amend_reason, changed_by)
    VALUES (p_work_order_id, 'closed', 'runs=' || v_runs::text, btrim(p_reason), v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'closed', 'runs', v_runs);
END;
$function$

;
