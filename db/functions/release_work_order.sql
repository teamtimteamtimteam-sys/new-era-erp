CREATE OR REPLACE FUNCTION public.release_work_order(p_work_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_wo      work_orders%ROWTYPE;
    v_appr_on boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'draft' THEN
        RAISE EXCEPTION 'WO_NOT_DRAFT|%|%', v_wo.code, v_wo.status;
    END IF;

    -- 【放行是那个要有人负责的动作】(WO-1b)Doc 2 点名要"who approved the work
    -- order"。可审批的是放行 —— 不是新建(草稿谁都可以写),也不是收工(事后记录)。
    -- 【层级用 1,而不是按金额分档】工单没有金额,approval_level_for 是按金额分的,
    -- 对一张没有钱的单据问它属于哪一档没有意义(与 leave_request /
    -- performance_review / stocktake 同一类)。
    IF v_appr_on THEN
        PERFORM require_approver_for(1::smallint);
    END IF;

    UPDATE work_orders
       SET status = 'released', updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, changed_by)
    VALUES (p_work_order_id, 'released', v_user);

    -- 【关着的时候也要留痕,而且要说实话】—— 与 create_purchase_order 逐字同一句:
    -- 记录真实发生的事,不要把"系统直接盖章"伪装成一次人的决定。
    IF v_appr_on THEN
        PERFORM record_approval_decision('work_order', p_work_order_id, 'approved', 1::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('work_order', p_work_order_id, 'auto_approved', NULL,
            '审批流未启用(finance_settings.approvals_enabled = false)—— 系统直接盖章,没有人做过这个决定');
    END IF;

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'released', 'approvals_enabled', v_appr_on);
END;
$function$

;
