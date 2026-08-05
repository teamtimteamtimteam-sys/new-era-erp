-- db/migrations/2026-08-06-fin19-reach-back-only-from-non-publication-days.sql
--
-- FIN-19:回溯只允许【交易日本身是非发布日】的时候。
--
-- 【FIN-13 那条规则对连续两天是空真的】原文是"牌价日与交易日【之间】的每一天
-- 都必须是非发布日",实现为
--     generate_series(v_when + 1, p_date - 1)
-- 当牌价日恰好是交易日的前一天,这个区间【是空的】—— 没有任何一天需要检查,
-- EXISTS 为假,于是放行。结论:任何一个工作日都会无声地接受昨天的牌价。
--
-- 这正是 FIN-0 从 pay_medical_claim 里删掉的那个"就近取一条"的查找,
-- 只不过这次它披着一条看起来很严格的规则。规则越像话,越没人再去验它。
--
-- 【线上实证】8 月 5 日录了牌价,8 月 6 日没录;6 日(周四,工作日)的收货
-- 静默取了 5 日的 1.24。改动前后逐日比对全部已过账外币分录,受影响的
-- (日期, 币种, 侧) 恰好只有 2026-08-06 的 tt_buy 与 tt_sell —— 就是这一笔。
--
-- 【正确的写法】回溯的正当性来自"那天市场根本不发布牌价"。所以真正的条件是:
-- 从牌价日(不含)到【交易日本身(含)】的每一天都是非发布日。
-- 交易日是工作日 ⇒ 它自己就落进这个区间 ⇒ 立即拒绝,与精确匹配一模一样。
-- 实现上只差一个 token:p_date - 1 → p_date。
--
-- 【原来测过的边界一条不少】
--   * 周六交易取周五:区间 = {周六},非发布日 → 仍放行;
--   * 周一交易取周五:区间 = {周六, 周日, 周一},周一是工作日 → 【现在拒绝】。
--     这一条是【有意的行为变更】,不是过期的期望值:周一是普通工作日,
--     那天该录牌价没录,就该拒。fixture 09 第②臂随之反向,理由写在那里。
--   * 2030 农历新年的四天:周六 + 周日(初一) + 周一(初二) + 周二(顺延假),
--     交易日周二【本身是假日】→ 区间四天全非发布 → 仍放行,4 天硬上限照旧兜底。
--
-- 【伦敦 vs 新加坡日历】AGENTS.md 早就写着"失败方向是英国公共假日误判为工作日
-- → 拒绝,偏保守且自己会报出来,不会悄悄用错价"。在此之前那句话是【不成立的】:
-- 那种日子只要前一天有牌价就会被静默放行。这个改动让文档描述的性质第一次为真。
--
-- 【顺带的后果,是对的】fx_rate_gaps 会开始把"工作日没录牌价"报出来 ——
-- 它本来就是那张漏课账单。2026-08-06 会立刻出现在里面。

BEGIN;

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

-- 自检:直接拿【走查里那一笔】当断言对象 —— 8/5 有牌价、8/6 没有,8/6 是工作日。
-- 不插任何数据(currencies.code 有 CHECK,试过插测试币种,迁移整体回滚,库分毫未动),
-- 断言就落在真实数据上,这比造一对合成日期更有说服力。
DO $mig$
DECLARE v_rate numeric; v_asof date;
BEGIN
    -- 前提自证:8/6 是工作日,且它自己没有牌价 —— 否则这条自检什么也没测到
    IF NOT is_business_day(DATE '2026-08-06') THEN
        RAISE EXCEPTION 'FIN19_SELFCHECK_PRECONDITION|2026-08-06 应为工作日';
    END IF;
    IF EXISTS (SELECT 1 FROM fx_rates WHERE currency='USD' AND rate_date=DATE '2026-08-06'
                 AND rate_type='tt_sell' AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'FIN19_SELFCHECK_PRECONDITION|2026-08-06 已经录了牌价,这条自检测不到东西了';
    END IF;

    -- ① 工作日 + 只有昨天的牌价 → 必须拒绝(空真的那一条)
    SELECT a.rate, a.as_of INTO v_rate, v_asof FROM fx_rate_asof('USD', DATE '2026-08-06', 'tt_sell') a;
    IF v_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FIN19_SELFCHECK_FAILED|8/6(工作日)仍取到了 % (as_of %) —— 空真那一条没修掉', v_rate, v_asof;
    END IF;

    -- ② 精确匹配不能被误伤:8/5 自己有牌价,必须照常返回且 as_of = 8/5
    SELECT a.rate, a.as_of INTO v_rate, v_asof FROM fx_rate_asof('USD', DATE '2026-08-05', 'tt_sell') a;
    IF v_rate IS NULL OR v_asof <> DATE '2026-08-05' THEN
        RAISE EXCEPTION 'FIN19_SELFCHECK_FAILED|精确匹配被误伤:rate=% as_of=%', v_rate, v_asof;
    END IF;
END
$mig$;

COMMIT;
