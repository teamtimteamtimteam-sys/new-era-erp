-- db/functions/price_exposure_report.sql
-- COMM-1:价格敞口 —— 一份【说得出自己看不见什么】的报告。
--
-- ★★【先例:PARTY-1 的 counterparty_overlap_report()】★★
--   它带【分母】,因为线上 customers 一个 tax_id 都没有 ——
--   「0 条重叠」与「没有可比的东西」长得一模一样,正是本仓库反复付账的那种沉默。
--   **为什么是函数不是视图:一个视图给不出分母(0 行就是 0 行)。**
--
-- ★★【本报告要分开【三种】本来都会印成 0 的零】★★
--   (i)   一份合同都没有                 → 分母是 0,问题还没有主语
--   (ii)  有合同,但没有一份写了计价条款   → 有主语,没有指数挂钩的敞口
--   (iii) ★【采购侧【没有被建模】】★ —— 一句关于【表结构】的话,不是关于数据的。
--         PRICE-1 只做了卖方向,而 §9「采购侧要不要也用指数联动」Tim 没有回答,
--         那一刀因此刻意不去扩 pricing_term_commitments。
--         于是队列那句「浮动价买进的吨数 vs 固定价卖出的吨数」——
--         **买进那一半今天在结构上就说不出来**,
--         它必须印成一句具名的话,**永远不能印成 0 吨**:
--         0 吨的意思是"我们没有浮动价买进",而真相是"这个系统还不会记这件事"。
--
-- 【单独一行报出:index_market_calendar 是空的】于是任何计价期均价都会按名拒。
--   它与"没有合同"是**两个不同的原因** —— 屏幕上长得一样的话,
--   读的人会以为只有一件事要修(PRICE-1 为日历与报价那两句留过同样的处置)。
--
-- ★【本刀的取舍规则,写在这里因为读到这份报告的人才需要它】★
--   同一刀里 RFQ 被【拒了】而这份报告【建了】,两者不矛盾:
--   **一个半成品的 RFQ 会【冒充】另一个问题的答案;
--     一个半成品的敞口报表【自己说出】它答不了的那一半。**
--   **一个会自报家门的缺口可以上线;一个要靠人记住的缺口不可以。**

CREATE OR REPLACE FUNCTION public.price_exposure_report()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_contracts_total       int;
    v_contracts_sell        int;
    v_contracts_buy         int;
    v_contracts_with_terms  int;
    v_terms_total           int;
    v_docs_linked           int;
    v_calendar_days         int;
    v_calendar_trading      int;
    v_quotes_total          int;
    v_quotes_indexed        int;
    v_sell_state            text;
    v_sell_rows             jsonb := '[]'::jsonb;
BEGIN
    -- 【SECURITY DEFINER 必须自己查权限】属主权限绕过 RLS,所以这一句不是礼节。
    -- 【为什么是 finance.view 这一个码】价格敞口是一个【钱的头寸】;
    --   而 AGENTS.md 的第 1 条常设裁定说得很死:module.finance.view 蕴含看得见价格
    --   (总账本身就是价格数据,对能读每一条分录的人遮价格是做样子)。
    PERFORM require_permission('module.finance.view');

    -- ── 分母:让每一个 0 说得出它是哪一种 0 ────────────────────────────────
    SELECT count(*),
           count(*) FILTER (WHERE side = 'sell'),
           count(*) FILTER (WHERE side = 'buy')
      INTO v_contracts_total, v_contracts_sell, v_contracts_buy
      FROM contracts WHERE deleted_at IS NULL;

    SELECT count(*), count(DISTINCT contract_id)
      INTO v_terms_total, v_contracts_with_terms
      FROM contract_pricing_terms;

    SELECT (SELECT count(*) FROM sales_orders    WHERE contract_id IS NOT NULL AND deleted_at IS NULL)
         + (SELECT count(*) FROM purchase_orders WHERE contract_id IS NOT NULL AND deleted_at IS NULL)
      INTO v_docs_linked;

    SELECT count(*), count(*) FILTER (WHERE is_trading_day)
      INTO v_calendar_days, v_calendar_trading
      FROM index_market_calendar;

    -- 【metal_prices 有 deleted_at,所以这里要滤】一条软删的报价不该进分母:
    -- 分母的全部用处是让"0 条挂了指数"说得出它是哪一种 0,
    -- 而把删掉的行算进去,会让"有 12 条报价、0 条挂指数"这句话本身失真。
    SELECT count(*), count(*) FILTER (WHERE price_index IS NOT NULL)
      INTO v_quotes_total, v_quotes_indexed
      FROM metal_prices WHERE deleted_at IS NULL;

    -- ── 卖方向:三种零里的前两种,由分母自己分辨 ────────────────────────────
    IF v_contracts_total = 0 THEN
        -- (i) 连主语都没有。**不是"敞口为零"。**
        v_sell_state := 'no_contracts';
    ELSIF v_contracts_with_terms = 0 THEN
        -- (ii) 有合同,但没有一份写了计价条款。
        -- 【为什么这一句这样措辞】contract_pricing_terms 的 index_code 是 NOT NULL,
        --   也就是说【这张表里的每一行按构造都是指数挂钩的】。
        --   所以"有条款但都不挂指数"在今天的表结构下【不存在】,
        --   它的真身是"没有一份合同写了计价条款"。照实说,不发明一个中间态。
        v_sell_state := 'no_pricing_terms';
    ELSE
        v_sell_state := 'open_positions_listed';
        -- 真的有条款时才算头寸:按合同 × 元素,把挂在该合同下的销售订单吨数摊出来。
        -- 【今天必然是空的,而这段代码【不是】装饰】—— 它是这份报告在数据到场那天
        --   会走的那一条路;先写好,才不会在有数据的那一天才发现它没写。
        SELECT COALESCE(jsonb_agg(x ORDER BY x->>'contract_code', x->>'metal'), '[]'::jsonb)
          INTO v_sell_rows
          FROM (
            SELECT jsonb_build_object(
                       'contract_id',   c.id,
                       'contract_code', c.code,
                       'metal',         t.metal,
                       'index_code',    t.index_code,
                       'base_event',    t.base_event,
                       'qp_months',     t.qp_months,
                       'payable_pct',   t.payable_pct,
                       -- 挂在这份合同下的销售订单吨数(未删除的单据)
                       'ordered_quantity', COALESCE(q.qty, 0)) AS x
              FROM contract_pricing_terms t
              JOIN contracts c ON c.id = t.contract_id AND c.deleted_at IS NULL
              LEFT JOIN LATERAL (
                    SELECT SUM(l.quantity) qty
                      FROM sales_orders so
                      JOIN sales_order_lines l ON l.sales_order_id = so.id
                     WHERE so.contract_id = c.id AND so.deleted_at IS NULL
              ) q ON true
          ) s;
    END IF;

    RETURN jsonb_build_object(
        -- ── 卖方向 ──────────────────────────────────────────────────────────
        'sell_side', jsonb_build_object(
            'state',     v_sell_state,
            'positions', v_sell_rows),

        -- ── ★ 买方向:一句关于【结构】的话,永远不是一个 0 吨 ★ ────────────
        'purchase_side', jsonb_build_object(
            'modelled', false,
            'why',
                'The purchase side of this question is NOT MODELLED — this is a statement '
                'about the schema, not about the data. PRICE-1 built index-linked pricing '
                'for the sell side only: contract_pricing_terms hangs off a contract and is '
                'read by sales documents. Whether purchasing uses index linkage at all is '
                'section 9 of docs/index-pricing-spec.md, which is recorded there as an open '
                'question awaiting Tim and which PRICE-1 deliberately did not answer (it '
                'refused to extend pricing_term_commitments, because an implied ruling is '
                'worse than an open question). So "floating-price tonnes bought" cannot be '
                'reported as 0 — 0 would mean we bought nothing on a floating price, whereas '
                'the truth is that this system does not yet record that fact at all.'),

        -- ── 均价能不能算:独立的一条,与"没有合同"不是同一件事 ────────────
        'quotational_period', jsonb_build_object(
            'calendar_days_loaded',  v_calendar_days,
            'calendar_trading_days', v_calendar_trading,
            'average_available',     (v_calendar_trading > 0),
            'why',
                CASE WHEN v_calendar_days = 0 THEN
                    'index_market_calendar is EMPTY, so every quotational-period average '
                    'refuses by name (index_period_average() requires a trading day for each '
                    'day of the period). This is a DATA gap, not a code gap, and it is a '
                    'DIFFERENT reason from having no contracts — a reader who sees only one '
                    'of the two will think there is only one thing to fix.'
                ELSE
                    'A market calendar is loaded; a quotational-period average can be '
                    'computed for the days it covers.'
                END),

        -- ── 分母 ────────────────────────────────────────────────────────────
        'coverage', jsonb_build_object(
            'contracts_total',            v_contracts_total,
            'contracts_sell_side',        v_contracts_sell,
            'contracts_buy_side',         v_contracts_buy,
            'contracts_with_pricing_terms', v_contracts_with_terms,
            'pricing_terms_total',        v_terms_total,
            'documents_linked_to_contract', v_docs_linked,
            'metal_quotes_total',         v_quotes_total,
            'metal_quotes_carrying_index', v_quotes_indexed),

        -- 跟着数字走的那句话,不只躺在文档里(同 PARTY-1 的处置)
        'zero_is_not_the_same_as_unknown', true);
END;
$function$;

COMMENT ON FUNCTION public.price_exposure_report() IS
'COMM-1:价格敞口 —— 一份【说得出自己看不见什么】的报告,先例是 PARTY-1 的 counterparty_overlap_report(带分母;为什么是函数不是视图:一个视图给不出分母,0 行就是 0 行)。**它分开三种本来都会印成 0 的零**:(i) 一份合同都没有(分母 0,问题还没有主语);(ii) 有合同但没有一份写了计价条款(注:contract_pricing_terms.index_code 是 NOT NULL,所以"有条款但不挂指数"在今天的结构下不存在,照实说成"没有合同写了计价条款");(iii) ★采购侧【没有被建模】★ —— 一句关于表结构的话,不是关于数据的:PRICE-1 只做卖方向,§9 采购侧是敞着的问题,所以「浮动价买进的吨数」永远不印成 0 吨,而是印成一句具名的话。另外单独一行报出 index_market_calendar 是空的(均价会按名拒)—— 那与"没有合同"是两个不同的原因,长得一样会让人以为只有一件事要修。**它不把两侧轧成一个净敞口**:卖方向有结构、买方向没有,相减得到的数字看起来确定,而两个加数不是同一种东西。';
