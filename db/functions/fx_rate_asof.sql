-- FIN-13(2026-08-05):汇率可以就近取上一个【发布日】,有界、有留痕;
-- 另有 4 个自然日的硬上限。fx_rate_asof 同时返回【实际取自哪一天】。
-- 理由与 4 天的由来见 db/migrations/2026-08-05-fin13-rate-asof-and-business-days.sql。
--
-- FIN-19(2026-08-06):FIN-13 那条规则【对相邻两天是空真的】。原文写的是
-- "牌价日与交易日【之间】的每一天都必须是非发布日",实现为
-- generate_series(v_when + 1, p_date - 1) —— 牌价日恰是交易日前一天时区间为空,
-- 条件恒成立,于是【任何工作日都会无声接受昨天的牌价】。那正是 FIN-0 从
-- pay_medical_claim 删掉的静默就近查找,披着一条看起来很严的规则长了回来。
-- 正确的条件是:从牌价日(不含)到【交易日本身(含)】全是非发布日 ——
-- 交易日是工作日就自己落进区间,当场拒绝,与精确匹配等价。
-- 只差一个 token(p_date - 1 → p_date),见
-- db/migrations/2026-08-06-fin19-reach-back-only-from-non-publication-days.sql。

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

    -- ════════════════════════════════════════════════════════════════════════
    -- 【关键一条 —— FIN-19 修正】从牌价日(不含)到【交易日本身(含)】的每一天
    -- 都必须是非发布日。区间的右端是 p_date,不是 p_date - 1。
    --
    -- 回溯的正当性【只来自】"那天市场不发布牌价"。所以交易日自己必须先满足它:
    --   * 交易日是工作日 → 它自己就在区间里 → 拒绝(与精确匹配等价);
    --   * 交易日是周末/假日 → 继续检查中间跨过的日子有没有夹着工作日。
    -- 牌价日 = 交易日时区间为空,精确匹配照旧通过。
    --
    -- 原来写 p_date - 1,对【相邻两天】而言区间恒空 —— 条件空真,于是任何工作日
    -- 都能接受昨天的牌价。那就是 FIN-0 删掉的静默就近查找,重新长了回来。
    -- ════════════════════════════════════════════════════════════════════════
    IF EXISTS (
        SELECT 1 FROM generate_series(v_when + 1, p_date, interval '1 day') d
        WHERE is_business_day(d::date)
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT v_rate, v_when;
END;
$function$;
