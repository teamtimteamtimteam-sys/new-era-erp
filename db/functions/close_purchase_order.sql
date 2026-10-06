CREATE OR REPLACE FUNCTION public.close_purchase_order(p_purchase_order_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_po        record;
    v_prepaid   numeric;
    v_applied   numeric;
    v_unapplied numeric;
    v_received  numeric;
    v_ordered   numeric;
BEGIN
    -- ★ APR-10(Tim 的 grilling Q7):开单人本人(按人认),或此刻持这张单那一类开单码的人 —— 其余按名拒
    --   PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager,一份判据;屏幕读同一份 po_may_manage)。
    --   从前的门 module.purchasing.edit 不再够。
    PERFORM assert_po_manager(p_purchase_order_id);
    SELECT id, code, status, notes INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;
    IF v_po.status = 'closed' THEN
        RAISE EXCEPTION 'PO_ALREADY_CLOSED|%', v_po.code;
    END IF;

    -- 未抵扣预付 = 已付到该单的预付(posted 收付款)− 已抵扣到批次的部分。
    -- 大于 0 时必须写说明:这是【真金白银】躺在 1300 预付款项里,而这张单永远不会
    -- 再吸收它了 —— 退款、转到别的单、核销,系统今天都还没建模,所以允许关单,
    -- 但必须留下一句写下来的解释,不许无声搁浅。
    SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_prepaid
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;
    SELECT COALESCE(SUM(ppa.amount_base), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;
    v_unapplied := round(v_prepaid - v_applied, 2);

    IF v_unapplied > 0 AND (p_notes IS NULL OR btrim(p_notes) = '') THEN
        RAISE EXCEPTION 'CLOSE_NOTES_REQUIRED|%', v_unapplied;
    END IF;

    SELECT COALESCE(SUM(ib.quantity), 0) INTO v_received
    FROM inbound_batches ib
    WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL;
    SELECT COALESCE(SUM(pol.quantity), 0) INTO v_ordered
    FROM purchase_order_lines pol
    WHERE pol.purchase_order_id = p_purchase_order_id;

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    -- ★ U1-B(UNBLOCK-1 Q25):关单的理由进它自己的列(close_reason / closed_by),【notes 不再被改写】——
    --   从前这里把 "[YYYY-MM-DD HH:MI closed] 理由" 追加进人写的备注(还被印到发给供应商的 PDF 上),
    --   历史触发器把它记成一次没有理由的 header_update。现在 notes 一个字不动,历史另记一行 closed,理由在 amend_reason。
    UPDATE purchase_orders
    SET status = 'closed',
        closed_at = now(),
        closed_by = v_user,
        close_reason = NULLIF(btrim(COALESCE(p_notes, '')), ''),
        updated_by = v_user
    WHERE id = p_purchase_order_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);
    INSERT INTO purchase_order_history (purchase_order_id, change_type, amend_reason, changed_by)
    VALUES (p_purchase_order_id, 'closed', NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user);


    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', 'closed',
        'unapplied_prepayment_usd', v_unapplied,
        'received_qty', v_received,
        'ordered_qty', v_ordered,
        'receipt_pct', CASE WHEN v_ordered = 0 THEN NULL
                            ELSE round(v_received / v_ordered * 100, 2) END
    );
END;
$function$;