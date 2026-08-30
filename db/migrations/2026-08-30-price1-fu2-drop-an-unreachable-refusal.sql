-- PRICE-1 fu2:删掉 index_period_average 里那条【永远不可能触发】的重复报价拒绝。
--
-- 【fixture 148 当场抓到的】metal_prices 上已经有
--     UNIQUE NULLS NOT DISTINCT (metal, price_date, price_index)
-- 同一天同一指数同一金属插不进第二条 —— 于是 QP_DUPLICATE_QUOTE 是死代码。
-- **一条永远不可能触发的具名拒绝,是一句系统兑现不了的承诺**:它让读的人
-- 以为这里在防一件事,而那件事在更上游就已经不可能了。
-- 保证仍然成立,只是作者是那张表 —— fixture 148 F 臂改成断言那条约束还在。

BEGIN;
CREATE OR REPLACE FUNCTION public.index_period_average(p_index_code text, p_metal text, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- PRICE-1:一个指数在一段【计价期】内的均价 —— 交易日逐日,**缺一天就按名拒**。
--
-- ★★★【它与 calculate_metal_price_from_terms 的 'average' 是【两条不同的规矩】,
--       不是同一条规矩的两份实现 —— 不要"顺手"把它们合并】★★★
--   那一支:窗口是 `price_date BETWEEN ref-(avg_days-1) AND ref`,即**一段回看的
--   滚动窗口**;它**不看任何日历**;它把**窗口里碰巧有的那些行**取平均;
--   只有当一行都没有时才把该金属记进 skipped_metals。
--   **它那样做是对的,而且是 AGENTS.md 明文维护的一条裁定**:
--   allocate_processing_costs 走的是**生产**那条路,「缺一条行情不该让生产停下来」。
--   本支:窗口是**合同约定的那个自然月**(M+n);它**必须**看日历;
--   它要求**每一个交易日都有报价**,缺一天就 QP_QUOTE_MISSING。
--   **理由是主语不同**:那一支的产出是一个【物理事实的成本摊派】,
--   本支的产出是一张【要钱的单据】。
--   **同一个仓库,两条规矩,不同的主语** —— 生产不能因为缺一条行情而停,
--   而结算不能带着缺一条行情往下走。
--   (这段话在 calculate_metal_price_from_terms.sql 里也写了一份,位置对称,
--    因为会来合并它们的人可能从任何一侧进来。)
--
-- ★★【为什么"缺一天就拒",而不是"用它有的那些天算"】★★
--   一个会跳过的均值**算得出数、不报错、看起来完全正常** —— 它只是回答了
--   另一个问题(「我碰巧有的那几天的均价」),而把答案当成合同约定的那个数。
--   这与 FIN-0 是同一个缺陷:一次静悄悄的近似,被当成一次测量。
--   AGENTS.md 那条 FX 规矩说得最清楚:**编一个汇率与编一个税率是同一个谎。**
--
-- 拒绝(全部按名,全部在 messages/*.ts 里有双语文案):
--   PRICE_INDEX_UNKNOWN|<index>              指数不在册
--   INDEX_CURRENCY_NOT_STATED|<index>        指数没声明报价币种(会计政策 5.3)
--   QP_RANGE_INVERTED|<from>|<to>            期间首尾颠倒
--   QP_CALENDAR_NOT_COVERED|<idx>|<f>|<t>|<d>  日历没盖住这一段(<d> 是第一个缺的日子)
--   QP_NO_TRADING_DAYS|<idx>|<f>|<t>         盖住了,但一个交易日都没有
--   QP_QUOTE_MISSING|<idx>|<metal>|<d>       某个交易日没有报价 ← ★ 本刀最要紧的那条
DECLARE
    v_ccy      text;
    v_missing  date;
    v_trading  integer;
    v_quotes   integer;
    v_avg      numeric;
    v_legs     jsonb;
BEGIN
    IF p_index_code IS NULL OR p_metal IS NULL OR p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'QP_ARGUMENTS_REQUIRED';
    END IF;
    IF p_to < p_from THEN
        RAISE EXCEPTION 'QP_RANGE_INVERTED|%|%', p_from, p_to;
    END IF;

    -- ★★【权限【按名】拒,而不是让 RLS 把日历藏起来】★★(PRICE-1 fu1)
    --   这一条是写 fixture 时抓出来的,不是事后想到的:本函数是 SECURITY INVOKER,
    --   而 index_market_calendar 有 RLS。**没有 module.pricing.view 的读者,
    --   日历对他就是空的** —— 于是他拿到的是 QP_CALENDAR_NOT_COVERED,
    --   那读起来是「数据缺了」,而实情是「你没权限看」。
    --   **两者必须分得开**,那正是 lib/permissions.ts 存在的全部理由:
    --   null 已经有别的含义了。所以这里先问一次,并**按名**拒。
    IF NOT has_permission('module.pricing.view'::text) THEN
        RAISE EXCEPTION 'PRICING_PERMISSION_DENIED|%', 'module.pricing.view'
          USING HINT = '看得见计价期均价要有定价模块的查看权限 —— 这不是数据缺失,是权限';
    END IF;

    SELECT i.quote_currency INTO v_ccy
      FROM metal_price_indices i WHERE i.code = p_index_code AND i.is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PRICE_INDEX_UNKNOWN|%', p_index_code
          USING HINT = '指数要先在 metal_price_indices 里在册,均价才谈得上是"那个市场"的均价';
    END IF;
    -- 会计政策 5.3:没声明报价币种的指数【按名拒】,不假定它是美元。
    IF v_ccy IS NULL THEN
        RAISE EXCEPTION 'INDEX_CURRENCY_NOT_STATED|%', p_index_code;
    END IF;

    -- ── ① 日历盖住了这一段吗 ────────────────────────────────────────────────
    -- 【这一条排在最前面,而顺序是判据的一部分】没有日历,"交易日"这个词
    -- 在这段期间里【没有定义】—— 那时任何一个数都是编的。
    SELECT d::date INTO v_missing
      FROM generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
     WHERE NOT EXISTS (SELECT 1 FROM index_market_calendar c
                        WHERE c.index_code = p_index_code AND c.calendar_date = d::date)
     ORDER BY d LIMIT 1;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'QP_CALENDAR_NOT_COVERED|%|%|%|%', p_index_code, p_from, p_to, v_missing
          USING HINT = '这个指数的开市日历没有盖住这段计价期 —— 系统【不知道】那天开不开市,所以它不算,而不是拿它碰巧有的那几天算一个数出来';
    END IF;

    -- ── ② 盖住了,但一个交易日都没有 ────────────────────────────────────────
    -- 【空集不是零】一个跨越整段休市的期间,均价【不存在】,而不是 0。
    SELECT count(*) INTO v_trading
      FROM index_market_calendar c
     WHERE c.index_code = p_index_code AND c.calendar_date BETWEEN p_from AND p_to
       AND c.is_trading_day;
    IF v_trading = 0 THEN
        RAISE EXCEPTION 'QP_NO_TRADING_DAYS|%|%|%', p_index_code, p_from, p_to;
    END IF;

    -- ── ③ 同一天多于一条报价?**表上已经不可能了,所以这里【不】重复检查** ──
    --   写这一支的第一版在这里查过一次重复,而 fixture 148 当场证明那是**死代码**:
    --   metal_prices 上已经有
    --       UNIQUE NULLS NOT DISTINCT (metal, price_date, price_index)
    --   —— 同一天、同一指数、同一金属**插不进第二条**(NULLS NOT DISTINCT
    --   让它连未标指数的行也咬得住)。
    --   **一条永远不可能触发的具名拒绝,是一句系统兑现不了的承诺**:
    --   它让读的人以为这里在防一件事,而那件事在更上游就已经不可能了。
    --   所以那段检查删掉了,改由 fixture 148 F 臂**断言那条约束还在** ——
    --   保证仍然成立,只是它的作者是那张表,不是这支函数。

    -- ── ④ ★ 每一个交易日都要有报价,缺一天就拒 ★ ────────────────────────────
    -- 【注意这里是 `= p_index_code`,不是 IS NOT DISTINCT FROM】
    -- 一条**没标指数**的报价(price_index IS NULL)**不**算作 LME 的报价。
    -- 线上今天 10 行报价【全部】没标指数 —— 所以对着线上现有数据,
    -- 这条拒绝会照实说"这个交易日没有报价",而那正是实情。
    SELECT c.calendar_date INTO v_missing
      FROM index_market_calendar c
     WHERE c.index_code = p_index_code AND c.calendar_date BETWEEN p_from AND p_to
       AND c.is_trading_day
       AND NOT EXISTS (SELECT 1 FROM metal_prices mp
                        WHERE mp.metal = p_metal AND mp.deleted_at IS NULL
                          AND mp.price_index = p_index_code
                          AND mp.price_date = c.calendar_date)
     ORDER BY c.calendar_date LIMIT 1;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'QP_QUOTE_MISSING|%|%|%', p_index_code, p_metal, v_missing
          USING HINT = '计价期内有交易日没有行情 —— 均价【不能】由剩下那些天顶替:一个会跳过的均值算得出数、不报错,而它回答的是另一个问题';
    END IF;

    -- ── ⑤ 逐日换算再取平均 ──────────────────────────────────────────────────
    -- METAL-3 的规矩,原样沿用:**每条各按自己那一天换算,再平均**;
    -- 先平均再换会让期间内的一次汇率波动污染期间里的每一天。
    -- 换算走 metal_quote_to_usd —— **一处实现**,它缺汇率时自己抛 FX_RATE_MISSING。
    SELECT avg(x.usd), COALESCE(jsonb_agg(x.leg ORDER BY x.d), '[]'::jsonb), count(*)
      INTO v_avg, v_legs, v_quotes
      FROM (SELECT c.calendar_date AS d, q.usd, q.leg
              FROM index_market_calendar c
              JOIN metal_prices mp
                ON mp.metal = p_metal AND mp.deleted_at IS NULL
               AND mp.price_index = p_index_code AND mp.price_date = c.calendar_date
              CROSS JOIN LATERAL metal_quote_to_usd(mp.price_usd_per_tonne, v_ccy, mp.price_date) q
             WHERE c.index_code = p_index_code
               AND c.calendar_date BETWEEN p_from AND p_to AND c.is_trading_day) x;

    RETURN jsonb_build_object(
        'index_code',        p_index_code,
        'metal',             p_metal,
        'qp_from',           p_from,
        'qp_to',             p_to,
        'trading_days',      v_trading,
        'quotes_used',       v_quotes,
        'quote_currency',    v_ccy,
        'avg_usd_per_tonne', round(v_avg, 4),
        -- 【逐条记下出处,于是这个均价可以被【重导出】,而不是被相信】
        'legs',              v_legs);
END
$function$;

COMMENT ON FUNCTION public.index_period_average(text, text, date, date) IS
    'PRICE-1:一个指数在一段计价期内的均价 —— **交易日逐日,缺一天按名拒**(QP_QUOTE_MISSING)。★★**它与 calculate_metal_price_from_terms 的 average 是两条不同的规矩,不是同一条规矩的两份实现 —— 不要合并**★★:那一支的窗口是一段**回看的滚动窗口**、**不看任何日历**、把**碰巧有的那些行**取平均,一行都没有时把该金属记进 skipped_metals 而不中止 —— **那样做是对的**,AGENTS.md 明文维护它,因为 allocate_processing_costs 走的是**生产**那条路,缺一条行情不该让生产停下来。本支的窗口是**合同约定的那个自然月**,必须看 index_market_calendar,要求每个交易日都有报价。**主语不同**:那一支的产出是物理事实的成本摊派,本支的产出是**一张要钱的单据**。★**为什么缺一天就拒**★:一个会跳过的均值**算得出数、不报错、看起来完全正常**,它只是回答了另一个问题(我碰巧有的那几天的均价)—— 与 FIN-0 同一个缺陷,而 AGENTS.md 那条 FX 规矩说得最清楚:**编一个汇率与编一个税率是同一个谎**。逐日换算再平均(METAL-3),换算走 metal_quote_to_usd 这一处实现;legs 逐条记出处,于是这个均价可以被**重导出**,而不是被相信。';
COMMIT;
