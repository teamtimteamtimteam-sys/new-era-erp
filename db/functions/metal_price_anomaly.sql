CREATE OR REPLACE FUNCTION public.metal_price_anomaly(p_metal text, p_price numeric, p_price_date date, p_price_index text DEFAULT NULL::text, p_exclude_id uuid DEFAULT NULL::uuid)
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
        RAISE EXCEPTION 'PRICING_SETTINGS_MISSING';
    END IF;

    -- 【METAL-2:参照必须来自【同一个指数】】LME 与 SMM 本来就不同价,跨着比会
    -- 天天报警 —— 而天天报警的警报等于没有警报,人会学会点掉它,连真的那次一起点掉。
    -- IS NOT DISTINCT FROM:未标注指数的老序列只与老序列比,不与任何新序列比。
    --
    -- 上一条:按 price_date,不按 created_at(补录会让 created_at 说谎 —— ASY-3
    -- 实测:6-25 的行情 7-2 才录进来)
    SELECT price_usd_per_tonne, price_date INTO v_ref_price, v_ref_date
      FROM metal_prices
     WHERE metal = p_metal AND deleted_at IS NULL
       AND price_index IS NOT DISTINCT FROM p_price_index
       AND price_date < p_price_date
       AND (p_exclude_id IS NULL OR id <> p_exclude_id)
     ORDER BY price_date DESC LIMIT 1;
    v_side := 'previous';

    IF v_ref_price IS NULL THEN
        -- 没有更早的一条:回落到最近的更晚一条,并说明用的是哪一侧。
        SELECT price_usd_per_tonne, price_date INTO v_ref_price, v_ref_date
          FROM metal_prices
         WHERE metal = p_metal AND deleted_at IS NULL
           AND price_index IS NOT DISTINCT FROM p_price_index
           AND price_date > p_price_date
           AND (p_exclude_id IS NULL OR id <> p_exclude_id)
         ORDER BY price_date ASC LIMIT 1;
        v_side := 'later';
    END IF;

    IF v_ref_price IS NULL THEN
        -- 【第三种判词,不是 false】这个金属在【这个指数上】还没有别的报价可比。
        -- 两条序列之后这一种会更常见(每个金属在每个新指数上的第一条),
        -- 而它依然不等于"查过、没问题"。补上它需要 per-metal 的绝对区间:
        -- 7 个金属 × 上下界 = 14 个数字,那是一个决定,不是一次实现。
        RETURN jsonb_build_object(
            'verdict', 'no_reference',
            'metal', p_metal,
            'price_index', p_price_index,
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
        'price_index', p_price_index,
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