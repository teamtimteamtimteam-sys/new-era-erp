-- db/functions/fx_rate_for.sql
-- 【FIN-0 汇率政策的唯一取数口】某笔交易用的汇率 = 该交易【日期】当天、
-- 交易【方向】对应那一侧的行方牌价(暂定 DBS):
--   tt_buy  = 银行向我们买外币(收入、应收 —— 我们将来把外币卖给银行)
--   tt_sell = 银行卖外币给我们(支出、应付 —— 我们将来向银行买外币)
--   mid     = 中间价(重估值、无方向的口径)
--
-- 【当日没有就是没有】—— 拒绝(FX_RATE_MISSING),绝不取"最近一天"的凑数:
-- 牌价当天不录,隔天可能就查不回来了;错取邻日汇率比报错贵得多。
-- 【本函数只服务"没有发生兑换"的估值】(C4):真实换汇永远用银行水单上的
-- 实际两边金额,不查这张表 —— record_payment 的跨币种分支是那条路。
--
-- SECURITY INVOKER:被各 SECURITY DEFINER 过账函数调用时以属主身份运行;
-- 不需要自己的调用者检查(B2 不适用)。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin0-sgd-base-and-fx-policy.sql.

CREATE OR REPLACE FUNCTION public.fx_rate_for(p_currency text, p_date date, p_rate_type text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rate numeric;
BEGIN
    IF p_currency = 'SGD' THEN
        RETURN 1;  -- 本位币没有汇率这回事
    END IF;
    IF p_rate_type IS NULL OR p_rate_type NOT IN ('tt_buy', 'tt_sell', 'mid') THEN
        RAISE EXCEPTION 'FX_RATE_TYPE_INVALID|%', COALESCE(p_rate_type, '?');
    END IF;
    SELECT rate_sgd_per_unit INTO v_rate
    FROM fx_rates
    WHERE currency = p_currency AND rate_date = p_date
      AND rate_type = p_rate_type AND deleted_at IS NULL;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|%|%|%', p_currency, p_date, p_rate_type;
    END IF;
    RETURN v_rate;
END;
$function$;
