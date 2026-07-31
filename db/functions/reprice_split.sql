CREATE OR REPLACE FUNCTION public.reprice_split(p_quantity numeric, p_remaining numeric, p_old_price numeric, p_new_price numeric)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- ratio 用未取整的值参与乘法(与历来的入账口径一致),仅在输出时取到 4 位
    SELECT jsonb_build_object(
        'delta_usd', d.delta,
        'in_stock_ratio', round(d.ratio, 4),
        'inventory_share_usd', d.inv,
        'cost_share_usd', round(d.delta - d.inv, 2)
    )
    FROM (
        SELECT delta, ratio, round(delta * ratio, 2) AS inv
        FROM (
            SELECT round(p_quantity * (p_new_price - COALESCE(p_old_price, 0)), 2) AS delta,
                   CASE WHEN p_quantity = 0 THEN 1
                        ELSE LEAST(1, GREATEST(0, p_remaining / p_quantity)) END AS ratio
        ) x
    ) d;
$function$

