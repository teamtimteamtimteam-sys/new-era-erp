-- METAL-3 第五部分(2026-08-11):缺汇率要【自己抛】—— SELECT INTO 零行不会报错
--
-- 【fixture 50C 抓到的,而且抓的正是它被写出来要抓的那件事】
-- metal_quote_to_usd 用 `SELECT f.rate, f.as_of INTO r_ccy, a_ccy FROM fx_rate_asof(…) f`
-- 取汇率。但是:
--   * fx_rate_asof 查不到时【返回零行】,并不抛异常(抛异常的是标量版 fx_rate_for);
--   * plpgsql 的 SELECT ... INTO 遇到零行【不报错】,只把变量留成 NULL。
-- 于是 usd := price × NULL / NULL = NULL,而调用方 calculate_metal_price_from_terms
-- 把 NULL 价读成"这个金属没有行情",记进 skipped_metals、贡献 0。
--
-- 【结果是这一刀存在的理由的反面】一条真实发布的 90,000 CNY 报价,因为当天没有
-- 中间价,被安静地算成【不值钱】—— 与 METAL-2 抬头写的"另一个指数上正躺着一条好
-- 数字却按零算"是同一种失败,只是这次缺的是汇率而不是行情。
--
-- 【区别要守住】缺【行情】跳过(FIN-15 的分工,不变);缺【汇率】拒绝 ——
-- 我们手里有那个数字,只是表达不出来,而编一个汇率是 THE FX RULE 不许的。

BEGIN;

CREATE OR REPLACE FUNCTION public.metal_quote_to_usd(p_price numeric, p_quote_currency text, p_quote_date date)
 RETURNS TABLE(usd numeric, leg jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- 【USD 是本函数族的报价基准,不是本位币】金属按 USD/吨报价是市场惯例
    -- (AGENTS.md 已把它记成一条决定),而本位币是 SGD。两者不是一回事,
    -- 所以这里的 'USD' 不是"把本位币写死了"。
    c_quote_basis constant text := 'USD';
    v_base  text;
    r_ccy   numeric; a_ccy date;
    r_usd   numeric; a_usd date;
BEGIN
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    IF p_quote_currency IS NULL THEN
        RAISE EXCEPTION 'INDEX_CURRENCY_NOT_STATED|?';
    END IF;

    -- 报价本来就是 USD:不换算,也不去查任何汇率(没有汇率可编,也没有必要)
    IF p_quote_currency = c_quote_basis THEN
        usd := p_price;
        leg := jsonb_build_object(
            'quote_currency', p_quote_currency,
            'quote_date', p_quote_date,
            'original_price', p_price,
            'converted', false);
        RETURN NEXT;
        RETURN;
    END IF;

    -- 两条腿:报价币 → 本位币 → USD。汇率记的是【本位币 / 一单位外币】,
    -- 所以 usd = price × rate(报价币) / rate(USD)。本位币自己没有行(fx_rates 的
    -- CHECK 挡着),它的"汇率"恒为 1 —— 那是定义,不是兜底。
    IF p_quote_currency = v_base THEN
        r_ccy := 1; a_ccy := p_quote_date;
    ELSE
        -- 缺汇率【不是跳过,是拒绝】:我们手里有那条报价,只是表达不出来。
        -- fx_rate_asof 自己会抛 FX_RATE_MISSING|币种|日期|价种,并带着有界的就近取值。
        SELECT f.rate, f.as_of INTO r_ccy, a_ccy
        FROM fx_rate_asof(p_quote_currency, p_quote_date, 'mid') f;
        -- 【必须自己写这个拒绝】fx_rate_asof 在查不到时【返回零行,不抛异常】
        -- (抛的是标量版 fx_rate_for)。而 plpgsql 的 SELECT ... INTO 对零行
        -- 【不报错】,只是把变量留成 NULL —— 于是 usd 变成 NULL,调用方把它读成
        -- "这个金属没有行情"并跳过、计零。那正是本函数存在要挡住的那个失败:
        -- 一条真实发布的价格被算成不值钱。fixture 50C 抓到过这一版。
        IF r_ccy IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_MISSING|%|%|mid', p_quote_currency, p_quote_date;
        END IF;
    END IF;

    IF v_base = c_quote_basis THEN
        r_usd := 1; a_usd := p_quote_date;
    ELSE
        SELECT f.rate, f.as_of INTO r_usd, a_usd
        FROM fx_rate_asof(c_quote_basis, p_quote_date, 'mid') f;
        IF r_usd IS NULL THEN          -- 同上:另一条腿缺价同样是拒绝,不是跳过
            RAISE EXCEPTION 'FX_RATE_MISSING|%|%|mid', c_quote_basis, p_quote_date;
        END IF;
    END IF;

    usd := round(p_price * r_ccy / r_usd, 6);
    leg := jsonb_build_object(
        'quote_currency', p_quote_currency,
        'quote_date', p_quote_date,
        'original_price', p_price,          -- 【发布时的原始数字】,出处的根
        'converted', true,
        'rate_type', 'mid',                 -- 行情是参考价,不是成交价
        'rate_quote_ccy', r_ccy,
        'rate_quote_ccy_as_of', a_ccy,      -- 可能因非发布日就近取前一天
        'rate_usd', r_usd,
        'rate_usd_as_of', a_usd,
        'usd_per_tonne', usd);
    RETURN NEXT;
END;
$function$;

COMMIT;
