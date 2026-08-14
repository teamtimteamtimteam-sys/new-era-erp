CREATE OR REPLACE FUNCTION public.set_sales_order_status(p_order_id uuid, p_to text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
    v_cust  record;
    v_ok    boolean;
    v_res   record;
    v_freed numeric := 0;
    v_left  int;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_order FROM sales_orders WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;

    -- 【允许的去处,逐个状态写出来】
    v_ok := CASE v_order.status
        WHEN 'draft'     THEN p_to IN ('confirmed','cancelled')
        WHEN 'confirmed' THEN p_to IN ('closed','cancelled')
        WHEN 'closed'    THEN false      -- 终态
        WHEN 'cancelled' THEN false      -- 终态
        ELSE false
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'SO_TRANSITION_NOT_ALLOWED|%|%', v_order.status, p_to;
    END IF;

    IF p_to = 'cancelled' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
        RAISE EXCEPTION 'SO_CANCEL_REASON_REQUIRED|%', v_order.code;
    END IF;

    -- 【确认要看客户的信用冻结】一张确认了的订单是一个承诺;对一个被冻结的
    -- 客户做承诺,与 record_output_sale 拒绝给他发货是同一条判断,只是早一步。
    -- 【只看 credit_hold,不看额度】额度是随敞口变的,而订单还没产生敞口 ——
    -- 拿一个将来的数去拒绝一张今天的单,会把"可能超限"演成"已经超限"。
    IF p_to = 'confirmed' THEN
        SELECT credit_hold, code INTO v_cust FROM customers WHERE id = v_order.customer_id;
        IF v_cust.credit_hold THEN
            RAISE EXCEPTION 'SO_CUSTOMER_ON_HOLD|%', v_cust.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_order_lines WHERE sales_order_id = p_order_id) THEN
            RAISE EXCEPTION 'SO_NO_LINES|%', v_order.code;
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【作废即释放,而且在改状态【之前】做】
    -- 一张作废的订单不该继续扣着货 —— 那批货会以 committed 的身份留在账上,
    -- 谁也卖不掉、谁也投不了,而屏幕上没有任何东西解释为什么。
    -- 【为什么在 UPDATE 之前】释放走 release_reservation,它会重新读这一行;
    -- 放在后面就得让它面对一个已经作废的订单,那是给自己造一个例外。
    -- 放在前面,任何一条释放失败都会把整个作废一起回滚 —— 要么单据作废了、
    -- 货也放回来了,要么两件都没发生。
    -- 【closed 不释放,那是另一件事】走完的订单,它的货是发出去了,不是放回去了。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_to = 'cancelled' THEN
        FOR v_res IN
            SELECT r.id, r.qty
              FROM sales_order_reservations r
              JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             WHERE l.sales_order_id = p_order_id AND r.released_at IS NULL
             ORDER BY r.created_at
        LOOP
            PERFORM release_reservation(v_res.id, NULL, 'order cancelled: ' || btrim(p_reason));
            v_freed := v_freed + v_res.qty;
        END LOOP;

        -- 【断言,不是假设】上面那个循环跑完之后【不该】还剩活预留。
        -- 一条 release 悄悄没生效(将来有人给它加了一个提前 RETURN),
        -- 结果是一张作废的单还扣着货 —— 而那件事不会有任何东西报出来。
        SELECT count(*) INTO v_left
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
         WHERE l.sales_order_id = p_order_id AND r.released_at IS NULL;
        IF v_left <> 0 THEN
            RAISE EXCEPTION 'SO_CANCEL_RESERVATIONS_LEFT|%|%', v_order.code, v_left;
        END IF;
    END IF;

    -- 上下文标记:让冻结守卫知道是【转换函数】在动状态列(同 po_status_ctx)
    PERFORM set_config('evoltrya.so_status_ctx', '1', true);
    UPDATE sales_orders
       SET status       = p_to,
           confirmed_at = CASE WHEN p_to = 'confirmed' THEN now() ELSE confirmed_at END,
           closed_at    = CASE WHEN p_to = 'closed'    THEN now() ELSE closed_at END,
           cancelled_at = CASE WHEN p_to = 'cancelled' THEN now() ELSE cancelled_at END,
           cancel_reason= CASE WHEN p_to = 'cancelled' THEN p_reason ELSE cancel_reason END,
           updated_at   = now(),
           updated_by   = auth.uid()
     WHERE id = p_order_id;
    PERFORM set_config('evoltrya.so_status_ctx', '', true);

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (p_order_id, p_to, p_reason);

    RETURN jsonb_build_object('id', p_order_id, 'status', p_to,
                              'released_qty', v_freed);
END;
$function$

;
