CREATE OR REPLACE FUNCTION public.preview_reprice_inbound_batch(p_inbound_batch_id uuid, p_new_unit_price numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_old       numeric;
    v_qty       numeric;
    v_remaining numeric;
    v_usd       numeric;
    v_split     jsonb;
BEGIN
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

    -- 与提交路径同一舍入(USD 时 fx = 1)
    v_usd := round(p_new_unit_price, 4);
    v_split := reprice_split(v_qty, v_remaining, v_old, v_usd);

    RETURN jsonb_build_object(
        'old_unit_price', v_old,
        'new_unit_price', v_usd,
        'delta_usd', (v_split->>'delta_usd')::numeric,
        'in_stock_ratio', (v_split->>'in_stock_ratio')::numeric,
        'inventory_share_usd', (v_split->>'inventory_share_usd')::numeric,
        'cost_share_usd', (v_split->>'cost_share_usd')::numeric
    );
END;
$function$

