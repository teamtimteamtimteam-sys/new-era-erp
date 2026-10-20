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
    v_inv   text;
    v_short record;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_order FROM sales_orders WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;

    -- 【允许的去处,逐个状态写出来】
    -- SO-3b:履约两态落地,而它们【不在这张表的右边】—— partially_shipped /
    -- shipped 由 ship_order 按"已发 vs 已订"现算后写入(经 so_status_ctx),
    -- 不是人手点的。这张表只管【人能点的那些】。
    -- 【closed 现在要求发完货】confirmed → closed 那条路没了:一张还没发货的
    -- 订单"走完了"是说不通的,而此前它是可点的。
    -- 【发出去的货收不回来】partially_shipped 是终点之一:2500 已经释放进 4000、
    -- 库存已经离开台账,作废它需要的是【贷项凭证】(sales_records 表头停放的
    -- 未来概念),不是一次状态跳转。shipped 只能走向 closed,同理。
    -- ★ FIN-CHAIN-1(Tim 2026-10-20,APR-5 Q12 · Step 0 Q5):partially_shipped → closed 是一次【显式的短装收尾】——
    --   理由必填;还有【开了票、没发、也没被贷项取消】的数量就按名拒(先开未发货取消的贷项);
    --   剩下的预留当场释放;写一行历史。从不自动发生。作废(cancelled)仍然不许 —— 发出去的货收不回来。
    v_ok := CASE v_order.status
        WHEN 'draft'             THEN p_to IN ('confirmed','cancelled')
        WHEN 'confirmed'         THEN p_to IN ('cancelled')
        WHEN 'partially_shipped' THEN p_to IN ('closed')   -- 短装收尾(FIN-CHAIN-1);作废仍走贷项凭证
        WHEN 'shipped'           THEN p_to IN ('closed')
        WHEN 'closed'            THEN false      -- 终态
        WHEN 'cancelled'         THEN false      -- 终态
        ELSE false
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'SO_TRANSITION_NOT_ALLOWED|%|%', v_order.status, p_to;
    END IF;

    IF p_to = 'cancelled' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
        RAISE EXCEPTION 'SO_CANCEL_REASON_REQUIRED|%', v_order.code;
    END IF;

    -- ★ FIN-CHAIN-1(Tim 2026-10-20,APR-5 Q12 · Step 0 Q4):一张挂着【在册订单流发票】的订单不许作废 ——
    --   作废了它,那张票还在册:应收与 2500 的合同负债就挂在一张已经不存在的订单上。按名拒,
    --   并点名那张票;先提发票作废申请(CFO 批),票作废之后再来作废订单。不替人自动提申请(Q4)。
    IF p_to = 'cancelled' THEN
        SELECT i.code INTO v_inv
          FROM invoices i
         WHERE i.sales_order_id = p_order_id AND i.kind = 'order' AND i.status = 'issued'
         ORDER BY i.code
         LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'SO_CANCEL_HAS_LIVE_INVOICE|%|%', v_order.code, v_inv;
        END IF;
    END IF;

    -- ★ FIN-CHAIN-1:短装收尾的两道闸 —— 理由必填;每一条订单行【开票 − 未发货取消 − 已发】必须 ≤ 0。
    --   开票 − 取消只有一处推导(sales_order_line_releasable_all,ship_order 的天花板读同一张);已发 = Σ shipment_lines。
    --   一张在等 CFO 的未发货取消贷项还没有落账,所以那一截仍然算"没取消" —— 等它批了再收尾。
    IF v_order.status = 'partially_shipped' AND p_to = 'closed' THEN
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
            RAISE EXCEPTION 'SO_CLOSE_REASON_REQUIRED|%', v_order.code;
        END IF;
        SELECT l.line_no, x.open_qty INTO v_short
          FROM sales_order_lines l
          CROSS JOIN LATERAL (
              SELECT COALESCE((SELECT sum(ra.releasable_qty) FROM sales_order_line_releasable_all ra
                                WHERE ra.sales_order_line_id = l.id), 0)
                   - COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl
                                WHERE sl.sales_order_line_id = l.id), 0) AS open_qty) x
         WHERE l.sales_order_id = p_order_id AND x.open_qty > 0
         ORDER BY l.line_no
         LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'SO_CLOSE_INVOICED_UNSHIPPED|%|%|%', v_order.code, v_short.line_no, trim_scale(v_short.open_qty);
        END IF;
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
    -- ★ FIN-CHAIN-1:【短装收尾】要释放 —— 没发的那一截不会再发了,扣着它就是谁也卖不掉的货。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_to = 'cancelled' OR (v_order.status = 'partially_shipped' AND p_to = 'closed') THEN
        FOR v_res IN
            SELECT r.id, r.qty
              FROM sales_order_reservations r
              JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             WHERE l.sales_order_id = p_order_id AND r.released_at IS NULL AND r.consumed_at IS NULL
             ORDER BY r.created_at
        LOOP
            PERFORM release_reservation(v_res.id, NULL,
                CASE WHEN p_to = 'cancelled' THEN 'order cancelled: ' ELSE 'order closed short: ' END || btrim(p_reason));
            v_freed := v_freed + v_res.qty;
        END LOOP;

        -- 【断言,不是假设】上面那个循环跑完之后【不该】还剩活预留。
        -- 一条 release 悄悄没生效(将来有人给它加了一个提前 RETURN),
        -- 结果是一张作废的单还扣着货 —— 而那件事不会有任何东西报出来。
        SELECT count(*) INTO v_left
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
         WHERE l.sales_order_id = p_order_id AND r.released_at IS NULL AND r.consumed_at IS NULL;
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
