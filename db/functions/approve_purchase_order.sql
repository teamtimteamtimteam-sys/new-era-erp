CREATE OR REPLACE FUNCTION public.approve_purchase_order(p_po_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_base  numeric;
    v_level smallint;
BEGIN
    PERFORM require_permission('module.purchasing.view');
    -- ★★【R4:批的人必须看得见他批的那个数】★★(CHAIN-BUILD-1,2026-08-30)
    --   本函数按【金额】选级别(approval_level_for),而金额在 purchase_orders_masked /
    --   purchase_order_lines_masked 上是遮蔽列,门是 data.view_prices。
    --   于是一个只持 module.purchasing.view 的人可以【打开单据、按下批准】,
    --   而屏幕上那一格写着「受限」—— 他批的是一个自己看不见的数字。
    --
    --   【为什么是"要这个权限",不是"在审批路径上解遮蔽"】(4a 的两条路,选了前者)
    --   解遮蔽会开出【第二条看价格的路】,绕过 _masked 那一套 —— 而那一套自己带着
    --   gate 的 colgrant / colreader 两条判词。多一条路 = 多一份定义,正是本仓库
    --   反复付账的那个形状。这里不发明新权限码,只是要求一个【已经存在】的。
    --
    --   【它与开关那道闸不重复,两者问的不是同一件事】
    --     · 开关时问:这个【角色】看得见金额吗(策略层面,可全知,后果是全体)
    --     · 批准时问:这个【人】看得见金额吗(个体层面,权限是多角色的并集)
    --   与 AGENTS.md「决定期间的值:控件禁用 + 服务端独立拒绝」是同一个两道闸的形状。
    PERFORM require_permission('data.view_prices');
    -- APR-2c:审批未生效时,"批准"是一个没有意义的动作 —— 单据本来就已经是 approved。
    -- 点名拒绝,而不是默默成功:后者会让人以为审批流在跑。
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    SELECT id, code, created_by, approval_status, status, currency, fx_rate, estimated_total_ccy
    INTO v_po FROM purchase_orders WHERE id = p_po_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;
    IF v_po.approval_status <> 'pending' THEN
        RAISE EXCEPTION 'PO_NOT_PENDING|%|%', v_po.code, v_po.approval_status;
    END IF;

    -- 【四眼】提单的人不能自己批。与 approve_review 的 SELF_APPROVAL_FORBIDDEN 同名同理。
    IF v_po.created_by IS NOT NULL AND v_po.created_by = auth.uid() THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN';
    END IF;

    -- 【本位币比,用单据自己存的汇率】(决定 3)。FIN-35 删掉了 fx_rate 的默认值,
    -- 所以一张外币单要么带着真汇率,要么根本不存在 —— 这里不必再防平价。
    v_base  := round(v_po.estimated_total_ccy * v_po.fx_rate, 2);
    v_level := approval_level_for(v_base);
    PERFORM require_approver_for(v_level);

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
    SET approval_status = 'approved',
        approved_at = now(),
        approved_by = auth.uid(),
        -- 批准把单据从 draft 推到 confirmed;advance_po_on_receipt 仍按 confirmed 走
        status = CASE WHEN status = 'draft' THEN 'confirmed' ELSE status END,
        updated_by = auth.uid()
    WHERE id = p_po_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);


    PERFORM record_approval_decision('purchase_order', p_po_id, 'approved', v_level, p_note);

    RETURN jsonb_build_object('purchase_order_id', p_po_id, 'code', v_po.code,
                              'level', v_level, 'amount_base', v_base);
END;
$function$;
