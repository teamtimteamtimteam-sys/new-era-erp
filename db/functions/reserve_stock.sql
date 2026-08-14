CREATE OR REPLACE FUNCTION public.reserve_stock(p_sales_order_line_id uuid, p_output_batch_id uuid, p_qty numeric, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_today    date := CURRENT_DATE;
    v_line     record;
    v_batch    record;
    v_avail    numeric;
    v_already  numeric;
    v_res_id   uuid;
BEGIN
    -- 【为什么是 module.sales.edit,而不是 module.inventory.edit】
    -- 预留就是一次销售行为 —— 做它的人是销售。给它挑一个"销售与库存都满足"的
    -- 权限码,只能挑一个比两者都松的,那不是把关、是把关的样子(与
    -- zzz_function_grants 给 drain_stock 写的那条理由同形)。而台账的不变量
    -- 不依赖调用者是谁:成对写入让物理总量按构造不动,check_no_negative_bucket
    -- 是约束触发器,对任何身份一视同仁。
    PERFORM require_permission('module.sales.edit');

    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'SO_RESERVE_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;

    SELECT l.id, l.quantity, l.material_id, l.line_no,
           o.id AS order_id, o.code AS order_code, o.status, o.deleted_at
      INTO v_line
      FROM sales_order_lines l
      JOIN sales_orders o ON o.id = l.sales_order_id
     WHERE l.id = p_sales_order_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_line_id::text, '?');
    END IF;

    -- 【只有确认了的订单才预留】草稿是还没答应的事,给它扣住货,等于让一张
    -- 随手建的单据把库存冻起来,而没有任何人做过那个承诺。
    IF v_line.deleted_at IS NOT NULL OR v_line.status <> 'confirmed' THEN
        RAISE EXCEPTION 'SO_RESERVE_ORDER_NOT_CONFIRMED|%|%',
            v_line.order_code, COALESCE(v_line.status, '?');
    END IF;

    -- 【产出批次,且还在】—— 见本表注释:预留一个进料批次会造出永远消耗不掉的
    -- 承诺库存(movement_type='sale' 被 inventory_movements_side 钉在产出侧)。
    SELECT ob.id, ob.code, ob.material_id, ob.unit
      INTO v_batch
      FROM output_batches ob
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVE_OUTPUT_ONLY|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF v_batch.material_id IS DISTINCT FROM v_line.material_id THEN
        RAISE EXCEPTION 'SO_RESERVE_MATERIAL_MISMATCH|%|%|%',
            v_batch.code,
            (SELECT code FROM materials WHERE id = v_batch.material_id),
            (SELECT code FROM materials WHERE id = v_line.material_id);
    END IF;

    -- 【行的天花板】一行订单最多只能许出它自己的数量。超过就是把同一批货
    -- 许给同一行两次 —— 屏幕上看不出来,发货时才炸。
    SELECT COALESCE(sum(r.qty), 0) INTO v_already
      FROM sales_order_reservations r
     WHERE r.sales_order_line_id = p_sales_order_line_id AND r.released_at IS NULL;
    IF v_already + p_qty > v_line.quantity THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_LINE|%|%|%', p_qty, v_line.quantity, v_already;
    END IF;

    -- 【就地求和,不调 derived_stock_qty】那个函数体里有
    -- require_permission('module.inventory.view'),而 has_permission 解析的是
    -- 【调用者】的 JWT —— DEFINER 换得了行的可见性,换不了函数体内那句对调用者
    -- 的判断。销售的人没有库存的码,调过去当场 PERMISSION_DENIED。
    -- record_output_sale 就地求和,同一个理由。
    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_avail
      FROM inventory_movements m
     WHERE m.output_batch_id = p_output_batch_id
       AND m.inbound_batch_id IS NULL
       AND m.location_id IS NOT DISTINCT FROM p_location_id
       AND m.stock_status = 'available';
    IF p_qty > v_avail THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_AVAILABLE|%|%', p_qty, v_avail;
    END IF;

    -- 成对:出 available、进 committed。同批次、同库位。物理总量按构造不动,
    -- remaining_qty 一个字不变,批次的 state 也不变(承诺不是销售)。
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'available', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user),
        (p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'committed', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user);

    INSERT INTO sales_order_reservations
        (sales_order_line_id, output_batch_id, location_id, qty, pair_id, created_by)
    VALUES (p_sales_order_line_id, p_output_batch_id, p_location_id, p_qty, v_pair, v_user)
    RETURNING id INTO v_res_id;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_line.order_id, 'reserved',
            format('line %s · %s %s %s', v_line.line_no, v_batch.code, p_qty, v_batch.unit));

    RETURN jsonb_build_object(
        'reservation_id', v_res_id, 'pair_id', v_pair, 'qty', p_qty,
        'output_batch_id', p_output_batch_id, 'location_id', p_location_id,
        'available_after', v_avail - p_qty,
        'line_reserved_after', v_already + p_qty,
        'line_quantity', v_line.quantity);
END;
$function$

;
