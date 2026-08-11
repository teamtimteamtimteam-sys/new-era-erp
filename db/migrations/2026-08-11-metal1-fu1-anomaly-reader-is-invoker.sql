-- METAL-1 fu1(2026-08-11):两个判据函数改回 SECURITY INVOKER
--
-- 【gate 的 B2 抓到的,而且抓对了】metal_price_anomaly 与
-- preview_metal_price_anomalies 原本写成 SECURITY DEFINER 且没有任何调用者检查,
-- 又对 authenticated 可执行 —— 那正是 B2 的定义:属主权限 + 不查调用者 + 调得到。
--
-- 【正确的修法是去掉 DEFINER,而不是加一句检查,更不是进 allowlist】
-- 它们只读两张表,而这两张表【自己的 RLS 就是公开给登录用户的】:
--     metal_prices     SELECT ... USING (true)      —— 行情是市场事实(OPS-15)
--     pricing_settings SELECT ... USING (true)      —— 阈值不是秘密,录入页要显示它
-- 属主权限在这里没有任何东西可以绕过,它只是把"按调用者解析"这件事白白关掉,
-- 并且要求后面每一个读代码的人相信一句"这里为什么不用查调用者"的解释。
-- 守卫跟着数据自己的 RLS 走(OPS-15 的规矩),这两个函数因此是 INVOKER。
--
-- 【触发器那个不动】trg_metal_price_anomaly 返回 trigger,调不动它;它的闸门是
-- 触发它的那次基表写入(perm2a 的设计),这一类由返回类型自动排除。
--
-- 签名一字未改 —— CREATE OR REPLACE 换的只是 security 属性。

BEGIN;

CREATE OR REPLACE FUNCTION public.metal_price_anomaly(
    p_metal text, p_price numeric, p_price_date date, p_exclude_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
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

CREATE OR REPLACE FUNCTION public.preview_metal_price_anomalies(
    p_price_date date, p_prices jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_el     jsonb;
    v_metal  text;
    v_raw    text;
    v_price  numeric;
    v_out    jsonb := '[]'::jsonb;
    v_exists uuid;
BEGIN
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;
    IF p_prices IS NULL OR jsonb_typeof(p_prices) <> 'array' THEN
        RAISE EXCEPTION 'NO_PRICES';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_prices)
    LOOP
        v_metal := v_el->>'metal';
        v_raw   := v_el->>'price_usd_per_tonne';
        -- 空格子跳过 —— 与 upsert_metal_prices 同一条:每日表单常常只填几个金属
        CONTINUE WHEN v_raw IS NULL OR btrim(v_raw) = '';
        v_price := v_raw::numeric;
        CONTINUE WHEN v_price IS NULL OR v_price <= 0;

        -- 覆盖已有的同日行时,那一行自己不能当参照
        SELECT id INTO v_exists FROM metal_prices
         WHERE metal = v_metal AND price_date = p_price_date AND deleted_at IS NULL;

        v_out := v_out || jsonb_build_array(
            metal_price_anomaly(v_metal, v_price, p_price_date, v_exists));
    END LOOP;

    RETURN v_out;
END;
$function$;

COMMIT;
