CREATE OR REPLACE FUNCTION public.reopen_purchase_order(p_purchase_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_po     record;
    v_status text;
BEGIN
    -- ★ APR-10(Tim 的 grilling Q7):开单人本人(按人认),或此刻持这张单那一类开单码的人 —— 其余按名拒
    --   PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager,一份判据;屏幕读同一份 po_may_manage)。
    --   从前的门 module.purchasing.edit 不再够。
    PERFORM assert_po_manager(p_purchase_order_id);
    SELECT id, code, status INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status <> 'closed' THEN
        RAISE EXCEPTION 'PO_NOT_CLOSED|%', v_po.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 已经收过货的回到 'receiving',一车没收过的回到 'confirmed'
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM inbound_batches ib
        WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL
    ) THEN 'receiving' ELSE 'confirmed' END INTO v_status;

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    -- ★ U1-B(UNBLOCK-1 Q25):重开的理由进它自己的列(reopen_reason / reopened_at / reopened_by),【notes 不再被改写】。
    --   单子不再是关着的,所以关单那三列清掉;那一次关单的全貌留在历史(closed 那一行)与变更记录里。
    UPDATE purchase_orders
    SET status = v_status,
        closed_at = NULL,
        closed_by = NULL,
        close_reason = NULL,
        reopened_at = now(),
        reopened_by = v_user,
        reopen_reason = btrim(p_reason),
        updated_by = v_user
    WHERE id = p_purchase_order_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);
    INSERT INTO purchase_order_history (purchase_order_id, change_type, amend_reason, changed_by)
    VALUES (p_purchase_order_id, 'reopened', btrim(p_reason), v_user);


    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', v_status
    );
END;
$function$;