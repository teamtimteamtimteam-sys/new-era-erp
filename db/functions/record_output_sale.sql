CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_unit_price numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_customer_id uuid DEFAULT NULL::uuid, p_sale_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_usd    numeric;
    v_movement_id   uuid;
    v_sale_id       uuid;
    v_sale_date     date := COALESCE(p_sale_date, CURRENT_DATE);
BEGIN
    SELECT deleted_at, remaining_qty INTO v_deleted, v_remaining
    FROM output_batches WHERE id = p_output_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QTY_INVALID';
    END IF;
    IF p_quantity > v_remaining THEN
        RAISE EXCEPTION 'SALE_EXCEEDS_REMAINING|%|%', p_quantity, v_remaining;
    END IF;

    -- cut 1 新增:销售必须带价(关闭"收入事件零金额"缺口)
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = 'USD' THEN
        v_fx := 1;  -- 本位币强制 1,忽略传入值
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;
    v_amount_usd := round(p_quantity * p_unit_price * v_fx, 2);

    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
    VALUES (p_output_batch_id, 'sale', -p_quantity, v_sale_date, p_notes, v_user)
    RETURNING id INTO v_movement_id;

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_usd, sale_date, notes, movement_id, created_by)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_usd, v_sale_date, p_notes, v_movement_id, v_user)
    RETURNING id INTO v_sale_id;

    -- 记账分录本 cut 不生成 —— cut 2 把 sale 事件接进 post_journal_entry。

    v_new_remaining := v_remaining - p_quantity;
    v_state := CASE WHEN v_new_remaining = 0 THEN '已售罄' ELSE '部分售出' END;

    UPDATE output_batches
    SET remaining_qty = v_new_remaining,
        state = v_state,
        updated_by = v_user,
        updated_at = now()
    WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'sold', p_quantity,
        'remaining_qty', v_new_remaining,
        'state', v_state,
        'sale_id', v_sale_id,
        'amount_usd', v_amount_usd
    );
END;
$function$
