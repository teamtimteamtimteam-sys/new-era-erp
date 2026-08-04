CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_unit_price numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_customer_id uuid DEFAULT NULL::uuid, p_sale_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_code          text;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_base    numeric;
    v_movement_id   uuid;
    v_sale_id       uuid;
    v_sale_date     date := COALESCE(p_sale_date, CURRENT_DATE);
    v_unit_cost     numeric;
    v_cogs          numeric;
    v_je1           jsonb;
    v_je2           jsonb;
BEGIN
    PERFORM require_permission('module.output.edit');
    SELECT deleted_at, remaining_qty, code INTO v_deleted, v_remaining, v_code
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

    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【交易日】的行方买入价(tt_buy)估值 ——
    -- 收入与应收是我们将来要【卖给银行】的外币。当日无牌价即拒(FX_RATE_MISSING),
    -- 不许悄悄用最近一天的。汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, v_sale_date, 'tt_buy');
    v_amount_base := round(p_quantity * p_unit_price * v_fx, 2);

    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
    VALUES (p_output_batch_id, 'sale', -p_quantity, v_sale_date, p_notes, v_user)
    RETURNING id INTO v_movement_id;

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date, notes, movement_id, created_by)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_base, v_sale_date, p_notes, v_movement_id, v_user)
    RETURNING id INTO v_sale_id;

    -- cut 2a JE#1:收入 —— 借 1100 / 贷 4000,原币行(amount_ccy = qty × price,
    -- fx 原样),USD 侧由 post_journal_entry 折算,与 amount_base 同式同值。
    v_je1 := post_journal_entry(
        v_sale_date,
        'Sale ' || v_code,
        'sale', v_sale_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx)));

    -- cut 2a JE#2:COGS —— 有产出腿单位成本才挂;没有则只挂收入(cogs_journal 为
    -- null),等 allocate_processing_costs 补挂(见其 COGS catch-up)。
    SELECT po.unit_cost_base INTO v_unit_cost
    FROM processing_outputs po
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    IF v_unit_cost IS NOT NULL THEN
        v_cogs := round(p_quantity * v_unit_cost, 2);
        IF v_cogs <> 0 THEN
            v_je2 := post_journal_entry(
                v_sale_date,
                'COGS ' || v_code,
                'sale', v_sale_id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
        END IF;
    END IF;

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
        'amount_base', v_amount_base,
        'revenue_journal', v_je1->>'code',
        'cogs_journal', v_je2->>'code'
    );
END;
$function$;