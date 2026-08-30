-- db/migrations/2026-08-30-comm1-commission-terms-and-price-exposure.sql
-- COMM-1:商务杂项四件里【活下来的两件】—— 佣金协议的条款,与价格敞口报表。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【本刀四件进来,两件出去 —— 而这条取舍规则要留给后来人】★★
--
--   队列把四件小事并成一刀,是【为了省事】,不是【允许做四个半成品】。
--   实测之后有两件被拒:
--
--   · **RFQ / 报价比对 —— 不做,断点名为 RFQ-1**(见 docs/forward-queue.md)。
--     库里今天的 `quotes` 是【卖方向】的(customer_id NOT NULL),
--     而 RFQ 问的是买方向:「我们问了三家,回来什么」。唯一的"收到的报价"先例
--     `forwarder_rate_quotes` 只记【答案】、不记【我们问过谁】——
--     于是"谢绝了"与"从来没问过"长得一模一样。
--     那正是 LOG-5a 在 free_days 上当成命根子的 NULL≠0 之分。
--     半个 RFQ 会【悄悄回答另一个问题】,所以一行都不建。
--
--   · **滞期费实际发生额 —— 不做,队列的推迟条件仍然成立**
--     (「折进物流候选清单,第一船真货之后重排」)。前提变了这件事已记进
--     docs/logistics-survey.md 的 A4.3 旁边:免柜期今天在【对的层级】上了
--     (forwarder_rate_quotes.free_days),看板第 23 支也已经在喊"正在产生滞港费";
--     而真正缺的【不是一个写下来的地方】—— 一笔滞港费今天就能记成一张 expenses
--     (日期必填、收款方是货代、会过账)。缺的是一条【会计裁定】:
--     进项滞港费要不要像运费那样进落地成本。**那一条不在代码里回答。**
--
-- ★【为什么拒 RFQ 而准价格敞口,不矛盾 —— 这是给未来所有"半刀"的判据】★
--
--     **一个半成品的 RFQ 会【冒充】另一个问题的答案;
--       一个半成品的敞口报表【自己说出】它答不了的那一半。**
--
--     **一个会自报家门的缺口可以上线;一个要靠人记住的缺口不可以。**
--
--   这句话同时写在 price_exposure_report() 的函数抬头上,因为读到那份报告的人
--   才是需要它的人。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【本刀建了什么】
--   1. commission_agreements —— 佣金【条款】。它不过账、不算账。
--   2. guard_commission_agreement_agent() —— 代理人必须是 service_vendor。
--   3. price_exposure_report() —— 一份【带分母】的报告,先例是
--      PARTY-1 的 counterparty_overlap_report():一个视图给不出分母(0 行就是 0 行)。
--
-- 【本刀【没有】建什么,而这些是【裁定过的缺席】,不是遗漏】
--   · 佣金的【计提】(从协议 + 那笔交易算出金额)—— 断点名 COMM-ACCRUAL-1。
--     理由:一笔佣金都没有付过,一条计提公式会被拟合到【零个案例】上。
--   · 佣金的【过账】—— 结算走既有的路:一张开给该 service_vendor 的 expenses,
--     它已经会过账、已经带 WHT(付给非居民代理人的佣金正是 wht_nature 的用处)。
--     先例明确:forwarder_rate_quotes「什么都不入账」、equipment_maintenance
--     「指着钱、自己不过账」。**指着钱不等于要进总账。**

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1 · commission_agreements —— 佣金条款
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★【recognition_trigger 是 NOT NULL 而且【没有默认值】—— 本表最要紧的一列】★★
--   义务【什么时候产生】不是一条可以由系统猜的规矩:不同代理人签的条款不同。
--   给它一个默认值,等于【系统替一个没有人签过的商业立场做主】,
--   而那个立场会决定确认期间 —— 本仓库对"决定期间的值永不默认"点过很多次名
--   (FIN-10 一族:十一支函数把 CURRENT_DATE 默认换成了具名拒绝)。
--   所以:三选一,必须有人说出来,说不出来就拒。
--
-- 【为什么是一列三值,而不是三张表 / 一个全局设定】
--   轴是列,值是行 —— 这是本仓库反复走的那条路(contract_pricing_terms 的
--   base_event 逐合同不同,也是一列三值)。
CREATE TABLE public.commission_agreements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- ── 代理人 ──────────────────────────────────────────────────────────────
    -- 【他是一个 supplier,而这【不是】将就】(COUNTERPARTY-ONE-PARTY 仍然开着)
    --   一个中间商既不是我们的客户、也不卖货给我们,他【提供服务】——
    --   而 suppliers.counterparty_type 里 'service_vendor' 这一档【本来就在】。
    --   先例是货代:一个不卖货的第三方,照样住在 suppliers 里,
    --   于是应付账龄、付款、预付冲抵、外币重估整条链一个字都不用改。
    --   **本刀因此不需要 parties 主表** —— 那次迁移的触发条件是批量导入,
    --   与本刀无关,而在这里提前动它正是 PARTY-1 拒绝过的形状。
    agent_supplier_id uuid NOT NULL REFERENCES public.suppliers (id),

    -- ── 它挂在哪一侧 ────────────────────────────────────────────────────────
    -- free_standing = 既不挂采购也不挂销售的一般代理约定(例如一份年度居间协议)。
    -- 【它不指向某一张单据】—— 指到单据是 COMM-ACCRUAL-1 的活,不是本刀的。
    side text NOT NULL
        CHECK (side IN ('purchase', 'sale', 'free_standing')),

    -- ── 计费口径 ────────────────────────────────────────────────────────────
    basis text NOT NULL
        CHECK (basis IN ('percentage_of_value', 'per_tonne', 'fixed_amount')),

    -- 【百分比与金额【互斥】,由 CHECK 强制】——
    -- 一行同时写着 2% 和 5000 元,读的人说不出哪个算数,而系统更说不出。
    rate_pct   numeric CHECK (rate_pct IS NULL OR (rate_pct > 0 AND rate_pct <= 100)),
    amount_ccy numeric CHECK (amount_ccy IS NULL OR amount_ccy > 0),
    -- 【币种是数据不是常量】(AGENTS.md:'USD'/'SGD' 永不出现在判断里)
    currency text REFERENCES public.currencies (code),

    -- ★ 义务何时产生 —— NOT NULL,无默认值。见本节抬头。
    recognition_trigger text NOT NULL
        CHECK (recognition_trigger IN ('on_shipment', 'on_invoice', 'on_counterparty_payment')),

    -- ── 有效期 ──────────────────────────────────────────────────────────────
    -- 与 forwarder_rate_quotes 同形:两端都必填,一份"从来没有有效过"的协议是录入错误。
    valid_from date NOT NULL,
    valid_to   date NOT NULL,

    -- 合同条款原文:自由文本【故意的】—— 佣金条款的写法千奇百怪,
    -- 把它塞进枚举等于假装我们见过所有写法。
    remarks text,

    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid DEFAULT auth.uid(),

    CONSTRAINT commission_agreements_validity_order
        CHECK (valid_to >= valid_from),

    -- 【口径决定填哪一格,三种口径三种形状】
    CONSTRAINT commission_agreements_basis_fields CHECK (
        (basis = 'percentage_of_value'
             AND rate_pct IS NOT NULL AND amount_ccy IS NULL AND currency IS NULL)
     OR (basis IN ('per_tonne', 'fixed_amount')
             AND rate_pct IS NULL AND amount_ccy IS NOT NULL AND currency IS NOT NULL)
    )
);

-- 按代理人查是这张表唯一的自然读法(一家代理人签了哪些协议)。
CREATE INDEX idx_commission_agreements_agent
    ON public.commission_agreements (agent_supplier_id);

COMMENT ON TABLE public.commission_agreements IS
'COMM-1:付给中间商 / 代理人的佣金【条款】。**它不过账、也不算账** —— 先例是 forwarder_rate_quotes(「什么都不入账」)与 equipment_maintenance(「指着钱、自己不过账」):指着钱不等于要进总账。一笔佣金真的要付时,走既有的路 —— 一张开给该 service_vendor 的 expenses,它已经会过账、已经带 WHT。**从协议算出金额那一半没有建**,断点名 COMM-ACCRUAL-1:一笔佣金都没有付过,一条计提公式会被拟合到零个案例上。代理人住在 suppliers 里(counterparty_type = service_vendor,先例是货代),所以本刀【不需要】parties 主表,COUNTERPARTY-ONE-PARTY 仍然开着。';

COMMENT ON COLUMN public.commission_agreements.recognition_trigger IS
'COMM-1:这笔佣金的义务【什么时候产生】—— 发运时 / 开票时 / 对方付款时。
★【NOT NULL 而且【没有默认值】,这是本表最要紧的一句】★
不同代理人签的条款不同,所以它是一条【逐协议的条款】,不是一个可以由系统猜的规矩。
给它一个默认值,等于系统替一个【没有人签过】的商业立场做主 —— 而这个立场决定确认期间,
正是 FIN-10 一族(十一支函数把 CURRENT_DATE 默认换成具名拒绝)反复付账的那一类。
说不出来就拒,不要替人填一个。';

COMMENT ON COLUMN public.commission_agreements.agent_supplier_id IS
'COMM-1:代理人 —— 一个 counterparty_type = ''service_vendor'' 的 supplier(由 guard_commission_agreement_agent() 强制)。他既不是客户也不卖货给我们,而 service_vendor 这一档本来就在。先例是货代:一个不卖货的第三方住在 suppliers 里,应付账龄 / 付款 / 预付冲抵 / 外币重估整条链因此一个字都不用改。';

COMMENT ON COLUMN public.commission_agreements.side IS
'COMM-1:这份协议挂在采购侧、销售侧,还是独立(free_standing,例如一份年度居间协议)。**它不指向某一张单据** —— 把协议连到具体那笔交易是 COMM-ACCRUAL-1 的活。';

COMMENT ON COLUMN public.commission_agreements.basis IS
'COMM-1:计费口径。percentage_of_value 填 rate_pct;per_tonne 与 fixed_amount 填 amount_ccy + currency。互斥由 commission_agreements_basis_fields 强制 —— 一行同时写着 2% 和 5000 元,读的人说不出哪个算数。';

-- ── 代理人必须是 service_vendor ──────────────────────────────────────────────
-- 形状逐字取自 guard_forwarder_details_is_forwarder():同一个问题(挂在一家
-- 对手方身上的属性,要求那一家【真的是那一类】),同一个处置。
CREATE OR REPLACE FUNCTION public.guard_commission_agreement_agent()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_type text;
    v_code text;
BEGIN
    SELECT counterparty_type, code INTO v_type, v_code
      FROM public.suppliers WHERE id = NEW.agent_supplier_id;
    IF v_type IS DISTINCT FROM 'service_vendor' THEN
        RAISE EXCEPTION 'COMMISSION_AGENT_NOT_SERVICE_VENDOR|%', COALESCE(v_code, NEW.agent_supplier_id::text)
          USING HINT = '佣金的收款方是一个提供服务的第三方 —— 先把这一家的 counterparty_type 改成 service_vendor,或者建一家';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_commission_agreements_agent
    BEFORE INSERT OR UPDATE ON public.commission_agreements
    FOR EACH ROW EXECUTE FUNCTION guard_commission_agreement_agent();

CREATE TRIGGER trg_commission_agreements_updated_at
    BEFORE UPDATE ON public.commission_agreements
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- 【为什么是 suppliers 而不是 purchasing / sales】这一行的【主语是代理人】,
--   而代理人是一个 supplier;每一行都有代理人,无论它挂哪一侧。
--   按 side 分权限会让 free_standing 那一档【无家可归】,
--   而按 purchasing 分会让一份销售侧的居间协议落在采购的门后面。
--   与 CONTRACT-1 把 /contracts 归在供应商模块之下是同一条判断。
ALTER TABLE public.commission_agreements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "commission_agreements select" ON public.commission_agreements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
CREATE POLICY "commission_agreements write" ON public.commission_agreements
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.suppliers.edit'::text))
    WITH CHECK (has_permission('module.suppliers.edit'::text));

-- ════════════════════════════════════════════════════════════════════════════
-- 2 · price_exposure_report() —— 一份【说得出自己看不见什么】的报告
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★【本仓库对报表的规矩:它必须说出它【看不见】什么。0 与"没有记录"是两个答案】★★
--
--   先例是 PARTY-1 的 counterparty_overlap_report():它带【分母】,
--   因为线上 customers 一个 tax_id 都没有 —— 「0 条重叠」与「没有可比的东西」
--   长得一模一样正是本仓库反复付账的那种沉默。
--   **为什么是函数不是视图:一个视图给不出分母(0 行就是 0 行)。**
--
-- ★★【本报告要分开的【三种】零,而它们本来都会印成 0】★★
--   (i)   一份合同都没有            → 分母是 0,连问题都还没有主语
--   (ii)  有合同,但没有一份写了计价条款 → 有主语,没有指数挂钩的敞口
--   (iii) ★【采购侧【没有被建模】】★ —— 这是一句关于【表结构】的话,不是关于数据的。
--         PRICE-1 只做了卖方向,而 §9「采购侧要不要也用指数联动」
--         **Tim 没有回答**,那一刀因此刻意不去扩 pricing_term_commitments。
--         于是队列那句「浮动价买进的吨数 vs 固定价卖出的吨数」——
--         **买进那一半今天在结构上就说不出来**。
--         它必须被印成一句【具名的话】,永远不能印成 0 吨:
--         0 吨的意思是"我们没有浮动价买进",而真相是"这个系统还不会记这件事"。
--
-- 【还有一条独立的原因,单独一行报出来】
--   index_market_calendar 是空的 —— 于是任何计价期均价都会【按名拒】。
--   它与"没有合同"是**两个不同的原因**,屏幕上长得一样的话,
--   读的人会以为只有一件事要修(PRICE-1 为日历与报价那两句留过同样的处置)。
--
-- 【它为什么不【也】把两侧加起来 / 轧成一个净敞口】
--   同 counterparty_overlap_report 的理由的一个变体:卖方向的敞口今天有结构、
--   买方向【没有】,把一个"有结构的 0"与一个"没有结构"相减,得到的是一个
--   看起来很确定的数字,而它的两个加数不是同一种东西。
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

COMMIT;
