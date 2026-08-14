CREATE OR REPLACE FUNCTION public.release_reservation(p_reservation_id uuid, p_qty numeric DEFAULT NULL::numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_pair   uuid := gen_random_uuid();
    v_today  date := CURRENT_DATE;
    v_res    record;
    v_order  record;
    v_want   numeric;
    v_rest   numeric;
    v_new    jsonb := NULL;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT r.*, l.line_no, l.sales_order_id
      INTO v_res
      FROM sales_order_reservations r
      JOIN sales_order_lines l ON l.id = r.sales_order_line_id
     WHERE r.id = p_reservation_id
     FOR UPDATE OF r;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVATION_NOT_FOUND|%', COALESCE(p_reservation_id::text, '?');
    END IF;
    IF v_res.released_at IS NOT NULL THEN
        RAISE EXCEPTION 'SO_RESERVATION_ALREADY_RELEASED|%', p_reservation_id;
    END IF;
    -- SO-3b:已经发出去的货放不回来 —— 更正走贷项凭证,不是"再释放一次"。
    IF v_res.consumed_at IS NOT NULL THEN
        RAISE EXCEPTION 'SO_RESERVATION_ALREADY_SHIPPED|%', p_reservation_id;
    END IF;

    -- 【释放要留下为什么,与暂扣同一条】一次没有理由的释放,过两天没人说得清
    -- 那批货为什么不再属于那张订单了。(hold_stock 的理由必填 / release_stock 的
    -- 备注可选,那处不对称是因为放开暂扣是"回到常态";这里不是 —— 撤回一个
    -- 已经做出的承诺【本身】就是一个需要解释的动作。)
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'SO_RELEASE_REASON_REQUIRED|%', p_reservation_id;
    END IF;

    v_want := COALESCE(p_qty, v_res.qty);
    IF v_want <= 0 OR v_want > v_res.qty THEN
        RAISE EXCEPTION 'SO_RELEASE_EXCEEDS|%|%', v_want, v_res.qty;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【部分释放 = 整行释放 + 就地重新预留剩余】
    -- 不是"把 qty 改小"。一行预留是一个发生过的事实(某日许了 40),把它改成
    -- 25 是在改写历史。整行释放之后再预留 15,留下的是两条都为真的事实,
    -- 合起来正好是发生过的经过 —— 而且流水侧一样对得上:先整笔 40 回到
    -- available,再 15 进 committed,净效果就是放回 25。
    -- 【重新预留走的是 reserve_stock 本身】,不是一段抄过来的插入:它会重新
    -- 走一遍订单状态、行天花板、桶余量三道检查。同一条规则,一个实现。
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (v_res.output_batch_id, v_res.location_id, 'status_change_out',
         -v_res.qty, 'committed', v_pair, v_today, btrim(p_reason), v_user),
        (v_res.output_batch_id, v_res.location_id, 'status_change_in',
          v_res.qty, 'available', v_pair, v_today, btrim(p_reason), v_user);

    UPDATE sales_order_reservations
       SET released_at     = now(),
           released_by     = v_user,
           release_reason  = btrim(p_reason),
           release_pair_id = v_pair
     WHERE id = p_reservation_id;

    v_rest := v_res.qty - v_want;
    IF v_rest > 0 THEN
        v_new := reserve_stock(v_res.sales_order_line_id, v_res.output_batch_id,
                               v_rest, v_res.location_id);
    END IF;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_res.sales_order_id, 'released',
            format('line %s · %s · %s', v_res.line_no, v_want, btrim(p_reason)));

    RETURN jsonb_build_object(
        'reservation_id', p_reservation_id,
        'released_qty', v_want,
        'release_pair_id', v_pair,
        'rereserved_qty', v_rest,
        'rereserved', v_new);
END;
$function$

;
