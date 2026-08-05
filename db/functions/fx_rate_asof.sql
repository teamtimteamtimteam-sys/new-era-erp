-- FIN-13(2026-08-05):汇率可以就近取上一个【发布日】,但有界、有留痕。
-- 中间跨过的每一天都必须是非发布日(周末 / SG 生效假日),夹着工作日即拒绝;
-- 另有 4 个自然日的硬上限。fx_rate_asof 同时返回【实际取自哪一天】。
-- 理由与 4 天的由来见 db/migrations/2026-08-05-fin13-rate-asof-and-business-days.sql。

CREATE OR REPLACE FUNCTION public.fx_rate_asof(p_currency text, p_date date, p_rate_type text)
 RETURNS TABLE(rate numeric, as_of date)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base text;
    v_cap  integer := 4;   -- 自然日上限,理由见文件头
    v_rate numeric;
    v_when date;
BEGIN
    IF p_rate_type IS NULL OR p_rate_type NOT IN ('tt_buy', 'tt_sell', 'mid') THEN
        RAISE EXCEPTION 'FX_RATE_TYPE_INVALID|%', COALESCE(p_rate_type, '?');
    END IF;

    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    -- 本位币没有汇率这回事:恒 1,不查牌价表(FIN-0)
    IF p_currency = v_base THEN
        RETURN QUERY SELECT 1::numeric, p_date;
        RETURN;
    END IF;
    IF p_date IS NULL THEN
        RETURN;   -- 没有日期就没有"当日牌价",交给调用方拒绝
    END IF;

    SELECT r.rate_sgd_per_unit, r.rate_date INTO v_rate, v_when
    FROM fx_rates r
    WHERE r.currency = p_currency AND r.rate_type = p_rate_type AND r.deleted_at IS NULL
      AND r.rate_date <= p_date AND r.rate_date >= p_date - v_cap
    ORDER BY r.rate_date DESC
    LIMIT 1;

    IF v_rate IS NULL THEN
        RETURN;   -- 上限之内一条都没有
    END IF;

    -- 【关键一条】牌价日与交易日之间的每一天都必须是非发布日。
    -- 夹着工作日 = 那天该录没录,不能拿更早的价蒙混过去。
    IF EXISTS (
        SELECT 1 FROM generate_series(v_when + 1, p_date - 1, interval '1 day') d
        WHERE is_business_day(d::date)
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT v_rate, v_when;
END;
$function$;
