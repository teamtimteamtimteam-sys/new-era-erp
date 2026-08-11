CREATE OR REPLACE FUNCTION public.metal_price_anomaly(p_metal text, p_price numeric, p_price_date date, p_exclude_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ref_price numeric;
    v_ref_date  date;
    v_side      text;
    v_threshold numeric;
    v_change    numeric;
BEGIN
    IF p_metal IS NULL OR p_price IS NULL OR p_price <= 0 OR p_price_date IS NULL THEN
        RAISE EXCEPTION 'METAL_PRICE_ANOMALY_INPUT|%|%|%', p_metal, p_price, p_price_date;
    END IF;

    SELECT metal_price_change_warn_pct INTO v_threshold FROM pricing_settings WHERE id;
    IF v_threshold IS NULL THEN
        -- 引导必须给出这一行(见 db/tables/pricing_settings.sql)。没有配置就
        -- 【说出来】,不要悄悄按某个数字判 —— 那正是本切要拆掉的东西。
        RAISE EXCEPTION 'PRICING_SETTINGS_MISSING';
    END IF;

    -- 上一条:按 price_date,不按 created_at(补录会让 created_at 说谎 —— ASY-3
    -- 实测:6-25 的行情 7-2 才录进来)
    SELECT price_usd_per_tonne, price_date INTO v_ref_price, v_ref_date
      FROM metal_prices
     WHERE metal = p_metal AND deleted_at IS NULL
       AND price_date < p_price_date
       AND (p_exclude_id IS NULL OR id <> p_exclude_id)
     ORDER BY price_date DESC LIMIT 1;
    v_side := 'previous';

    IF v_ref_price IS NULL THEN
        -- 没有更早的一条:回落到最近的更晚一条,并说明用的是哪一侧。
        -- 补录进序列【最前面】的那一条因此照样被检查。
        SELECT price_usd_per_tonne, price_date INTO v_ref_price, v_ref_date
          FROM metal_prices
         WHERE metal = p_metal AND deleted_at IS NULL
           AND price_date > p_price_date
           AND (p_exclude_id IS NULL OR id <> p_exclude_id)
         ORDER BY price_date ASC LIMIT 1;
        v_side := 'later';
    END IF;

    IF v_ref_price IS NULL THEN
        -- 【第三种判词,不是 false】这个金属还没有任何别的报价可比。
        -- 线上 7 个金属里有 4 个正是这样(al / fe / li / mn),而键错的第一条报价
        -- 一样是错的 —— "没法查"必须与"查过、没问题"在数据上就分得开,
        -- 界面才可能分得开。
        -- 【补上它需要什么】per-metal 的绝对区间:7 个金属 × 上下界 = 14 个数字,
        -- 那是一个决定(谁来给这些数字),不是一次实现。缺口明写在这里,
        -- 而不是让它安静地长成一句"检查过了"。
        RETURN jsonb_build_object(
            'verdict', 'no_reference',
            'metal', p_metal,
            'price_usd_per_tonne', p_price,
            'price_date', p_price_date,
            'threshold_pct', v_threshold,
            'reference_price', NULL,
            'reference_date', NULL,
            'reference_side', NULL,
            'change_pct', NULL,
            'checked_at', now()
        );
    END IF;

    v_change := round(abs(p_price - v_ref_price) / v_ref_price * 100, 2);

    RETURN jsonb_build_object(
        'verdict', CASE WHEN v_change > v_threshold THEN 'outside' ELSE 'inside' END,
        'metal', p_metal,
        'price_usd_per_tonne', p_price,
        'price_date', p_price_date,
        'threshold_pct', v_threshold,
        'reference_price', v_ref_price,
        'reference_date', v_ref_date,
        'reference_side', v_side,
        'change_pct', v_change,
        'checked_at', now()
    );
END;
$function$;