CREATE OR REPLACE FUNCTION public.cancel_purchase_order(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_po      record;
    v_batches integer;
    v_applied numeric;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, status INTO v_po
    FROM purchase_orders WHERE id = p_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    -- AUDEL-1b:【理由必填】此前是 DEFAULT NULL —— 取消一张采购单可以什么都不说,
    -- 而另外四个族(发票 / 工单 / 销售订单 / 报价)全都要求理由。这是第五份复制,
    -- 不是第六种变体:形状照抄 set_sales_order_status 的那一句。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PO_CANCEL_REASON_REQUIRED|%', v_po.code;
    END IF;

    SELECT count(*) INTO v_batches
    FROM inbound_batches WHERE purchase_order_id = p_id AND deleted_at IS NULL;
    IF v_batches > 0 THEN
        RAISE EXCEPTION 'PO_HAS_RECEIPTS|%', v_batches;
    END IF;

    SELECT COALESCE(SUM(amount_base), 0) INTO v_applied
    FROM prepayment_applications WHERE purchase_order_id = p_id;
    IF v_applied > 0 THEN
        RAISE EXCEPTION 'PO_HAS_APPLIED_PREPAYMENTS|%', v_applied;
    END IF;

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
    SET status = 'cancelled', cancelled_at = now(), cancel_reason = btrim(p_reason),
        cancelled_by = v_user, updated_by = v_user
    WHERE id = p_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    -- AUDEL-1b:写一行历史 —— 取消此前【不写】,而另外四个族都写。
    -- change_type 'cancelled' 是本刀加进 CHECK 的;changed_by 走列默认 auth.uid()。
    INSERT INTO purchase_order_history (purchase_order_id, change_type, amend_reason, changed_by)
    VALUES (p_id, 'cancelled', btrim(p_reason), v_user);

    RETURN jsonb_build_object('purchase_order_id', p_id, 'code', v_po.code, 'status', 'cancelled');
END;
$function$;
