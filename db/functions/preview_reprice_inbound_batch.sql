CREATE OR REPLACE FUNCTION public.preview_reprice_inbound_batch(p_inbound_batch_id uuid, p_new_unit_price numeric, p_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old       numeric;
    v_qty       numeric;
    v_remaining numeric;
    v_fx        numeric;
    v_fx_asof   date;
    v_base      numeric;
    v_split     jsonb;
    v_delta     numeric;
BEGIN
    PERFORM require_permission('data.view_prices');
    SELECT unit_price, quantity, remaining_qty
    INTO v_old, v_qty, v_remaining
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF p_new_unit_price IS NULL OR p_new_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    -- 【与 reprice_inbound_batch 逐行同构】本位币免换算;外币按【定价日】(即
    -- 提交时的 CURRENT_DATE)的 tt_sell 折算,缺牌价时用同一个 fx_rate_for 抛出
    -- 同一份 FX_RATE_MISSING|币种|日期|侧。少乘这一次就是 ASY-1 之前那个 56% 的差。
    SELECT a.rate, a.as_of INTO v_fx, v_fx_asof
    FROM fx_rate_asof(p_currency, CURRENT_DATE, 'tt_sell') a;
    IF v_fx IS NULL THEN
        PERFORM fx_rate_for(p_currency, CURRENT_DATE, 'tt_sell');
    END IF;

    v_base  := round(p_new_unit_price * v_fx, 4);
    v_split := reprice_split(v_qty, v_remaining, v_old, v_base);
    v_delta := (v_split->>'delta_usd')::numeric;

    -- 价差不为零时提交要过账 —— 过账过不去的日子,试算也不许说"可以"
    IF v_delta <> 0 THEN
        PERFORM assert_posting_allowed(CURRENT_DATE, 'purchase');
    END IF;

    RETURN jsonb_build_object(
        'old_unit_price', v_old,
        'new_unit_price', v_base,
        'delta_usd', v_delta,
        'in_stock_ratio', (v_split->>'in_stock_ratio')::numeric,
        'inventory_share_usd', (v_split->>'inventory_share_usd')::numeric,
        'cost_share_usd', (v_split->>'cost_share_usd')::numeric,
        -- 折算用的牌价与它取自哪天:屏幕上的数是怎么来的,要指得出来(FIN-21)
        'fx_rate', v_fx,
        'rate_as_of', v_fx_asof,
        'currency', p_currency
    );
END;
$function$;