-- PRICE-1:指数挂钩定价(M+1 / M+3)—— 规则记得住、价格算得出,而**缺一天就拒**。
--
-- 规格:docs/index-pricing-spec.md。§6 七问 Tim 已于 2026-08-29 全部裁定 ——
-- 建的时候读它,不要再推导一遍。
--
-- ★★【本刀停在 §7 第 2 步之后,而那是规格自己命名的诚实断点】★★
--   规格 §7 写着:「如果刀 4 装不下全部,**在 2 之后停是一个诚实的断点**:
--   那时候系统能记住规则、能算出价格,只是还没有两阶段开票 —— 这是一个可用的
--   中间状态。」本刀就停在那里,而且是**事先决定**的,不是做着做着停下的。
--
--   **停在这里之后,系统【会】做的:**
--     · 把计价期当成一条**合同条款**记下来(基准事件 / M+n / 指数 / 计价系数)
--     · 单据挂上合同那一刻把它**抄**进副本(FIN-26/27 的形状,与品位规格同一次动作)
--     · 算一个计价期的**指数均价**,交易日逐日,**缺一天按名拒**
--   **它【不会】做的(不要把"指数定价上线了"读成"我们能按指数开票了"):**
--     · 两阶段开票(暂定价发票 / 最终结算单)—— **没有**
--     · 计价期到期提醒(3 个工作日、Choo Er Teh)—— **没有**
--     · 最终结算的差额入账 —— **没有**(科目已裁定并写进会计政策 5.6,但**没建**)
--
-- ★【本刀只做【卖方向】】§9 明说「采购侧要不要也用指数联动,本文件没有答案,
--   需要 Tim 说明」。所以本刀不碰 pricing_term_commitments(买方向的承诺表)——
--   扩它等于替 Tim 把那个问题答了,而**一条被暗示的裁定比一个敞着的问题坏**。
--
-- 【本刀只加不删】新表两张、新函数两支、既有表加一列(可空有默认)、
--   两支既有函数 CREATE OR REPLACE(签名不变)。**没有 DROP、没有 RENAME。**
--   依赖清点:contract_document_terms **没有** _masked 孪生视图(实测),
--   所以那一列不触发 WO-1a 的"三件一起"(ADD COLUMN / GRANT / _masked);
--   它也没有列清单 SELECT 授权,表级授权自动覆盖新列。

BEGIN;

-- ═══ 1. 开市日历 —— 唯一能说出「那天市场关着」的东西 ══════════════════
-- db/tables/index_market_calendar.sql
-- PRICE-1:一个指数【哪几天开市】—— 这套系统里【唯一】能说出"那天市场是关着的"的东西。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【它为什么必须存在,而不是拿 public_holidays 凑合】★★
--
-- §6 第 4 条裁定:计价期均价**只算交易日**。而"只算交易日"要求系统分得开
-- **三个状态**,今天它一个都分不开:
--     ① 那天市场关着     ② 那天有报价     ③ 那天该有报价,但没人录
--
-- 唯一现成的日历是 `public_holidays`,而它**只有新加坡**(实测:14 行,全部
-- country='SG')。`is_business_day(date, country)` 虽然带国别参数,但库里没有
-- 任何非 SG 的行 —— 所以 `is_business_day(d,'GB')` 对**每一个英国银行假日**
-- 都会返回 true,而那是一次**空集造成的假答案**,不是一个答案。
--
-- ★【而拿 SG 日历当代理,失败的方向是错的】★ 这一条是本刀最要紧的判断:
--   · 某天**市场开着、而新加坡放假** → SG 代理说"非工作日" → 那一天被
--     **静悄悄地从均值里剔掉**。均价于是由"它碰巧有的那些天"撑起来 ——
--     **那正是本刀存在的理由要消灭的那个缺陷**(一个会跳过的均值)。
--   · 对比 FX 那条回溯(AGENTS.md 记着的 London/Singapore 近似):它用同一份
--     SG 日历,而**它失败的方向是【拒绝】** —— 英国银行假日会让它多拒一次,
--     保守、且自己会喊出来。
--   **同一份坏日历,在那里买到的是一次多余的拒绝,在这里买到的是一个错的数字。**
--   一个错的数字不会喊,而它会被开成发票。所以这里不用它。
--
-- ★★【为什么每一天都存,而不是只存休市日】★★
--   只存休市日的话,"没有行"就等于"开市" —— 于是一张**还没人加载过的空日历**
--   会宣称**每一天都开市**,而那是一次空集造成的假答案(与上面 is_business_day
--   撞的是同一堵墙)。逐日存下来之后,三个状态才真的分得开:
--     · 有行 + is_trading_day = true   → 那天开市
--     · 有行 + is_trading_day = false  → **那天市场关着**(这一条此前无处可说)
--     · **没有行**                      → **我们不知道那天开不开市** → 均价【按名拒】
--   第三条是重点:**"不知道"必须是一个可以被说出来的状态**,而不是被当成
--   "开市"或"休市"里更方便的那一个。
--
-- ★★【它出厂是【空的】,而那是刻意的】★★
--   本刀**没有**往里灌 LME / SMM 的 2026 年假日 —— 我手上没有权威来源,
--   而编一份出来正是本仓库明令禁止的那件事(把一个待答的问题伪装成已完成的数据)。
--   **今天的实际后果,写在这里而不是留给人发现:在有人加载日历之前,
--   任何一个计价期的均价都会【按名拒】(QP_CALENDAR_NOT_COVERED)。**
--   那是**对的** —— 系统不知道那些天开不开市,所以它说"我不知道",
--   而不是拿它碰巧有的那几天算一个数出来。
--
-- 【它不是"没有写入方的空表"】CONTRACT-1 拒绝预建 contract_pricing_terms,
--   理由是那张表**既没有写入方也没有读者**。这一张**从第一天起就有读者** ——
--   index_period_average 的那条拒绝就读它。一张空的日历不是没人看的表单,
--   它正是让系统说得出"我不知道那天开不开市"的那个机制。
--

CREATE TABLE public.index_market_calendar (
    index_code     text NOT NULL REFERENCES public.metal_price_indices (code) ON DELETE RESTRICT,
    calendar_date  date NOT NULL,
    -- 【三态里的前两态由这一列区分;第三态是"这一行不存在"】
    is_trading_day boolean NOT NULL,
    -- 休市的理由(春节 / 银行假日 / 交易所公告)—— 写下来,好让下一个人
    -- 判断这份日历是从哪儿来的,而不是相信它。
    note           text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid(),
    PRIMARY KEY (index_code, calendar_date)
);

CREATE INDEX idx_index_market_calendar_trading
    ON public.index_market_calendar (index_code, calendar_date) WHERE is_trading_day;

ALTER TABLE public.index_market_calendar ENABLE ROW LEVEL SECURITY;
-- 【读:任何能看定价的人】市场开不开市不是商业机密,它是公开事实;
-- 而读不到它的人会看到一次 QP_CALENDAR_NOT_COVERED,那读起来像"数据缺了",
-- 不像"你没权限" —— 两者必须分得开(lib/permissions.ts 存在的理由)。
CREATE POLICY "index market calendar select by pricing permission"
    ON public.index_market_calendar AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.pricing.view'::text));
CREATE POLICY "index market calendar write by pricing permission"
    ON public.index_market_calendar AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.pricing.edit'::text))
    WITH CHECK (has_permission('module.pricing.edit'::text));

COMMENT ON TABLE public.index_market_calendar IS
    'PRICE-1:一个指数哪几天开市 —— **这套系统里唯一能说出「那天市场是关着的」的东西**。★**为什么不拿 public_holidays 凑合**★:那份日历只有新加坡(实测 14 行全是 SG),而 is_business_day(date,country) 带国别参数却没有任何非 SG 的行,所以 is_business_day(d,''GB'') 对每一个英国银行假日都返回 true —— 一次**空集造成的假答案**。★★**而拿它当代理,失败的方向是错的**★★:某天市场开着、新加坡放假,SG 代理会把**一个真实的交易日静悄悄从均值里剔掉**,于是均价由"碰巧有的那些天"撑起来 —— 正是本刀要消灭的那个缺陷。对比 FX 那条回溯用同一份 SG 日历:**它失败的方向是【拒绝】**,保守且自己会喊。同一份坏日历,在那里买到一次多余的拒绝,在这里买到一个**错的数字**,而错的数字不会喊、会被开成发票。★**为什么逐日存,不只存休市日**★:只存休市日的话"没有行"就等于"开市",于是一张空日历会宣称每天都开市 —— 同一堵空集的墙。逐日之后三态才分得开:有行+true=开市、有行+false=**关市**、**没有行=我们不知道** → 均价按名拒(QP_CALENDAR_NOT_COVERED)。★**出厂是空的,刻意的**★:本刀没有灌 LME/SMM 的假日,因为手上没有权威来源,而编一份正是把待答问题伪装成已完成数据。**实际后果:在有人加载日历之前,任何计价期均价都会按名拒** —— 那是对的。**它不是「没有写入方的空表」**:CONTRACT-1 拒绝预建 contract_pricing_terms 是因为那张表既无写入方也无读者;这一张**从第一天起就有读者**(那条拒绝就读它)。';

COMMENT ON COLUMN public.index_market_calendar.is_trading_day IS
    'PRICE-1:那天这个市场开不开。**它只区分三态里的前两态** —— 第三态「我们不知道」由**这一行不存在**表示,而那一态会让均价按名拒。所以【不要】给这一列加默认值,也不要用"没有行 = 开市"去省掉半张表:那会把"不知道"悄悄变成"知道",而这正是本表存在的理由。';

-- ═══ 2. 计价条款:合同的第四个兄弟子表 ═══════════════════════════════
-- db/tables/contract_pricing_terms.sql
-- PRICE-1:指数挂钩定价的条款 —— **合同的第四个兄弟子表**。
--
-- 【它落在这里,是 CONTRACT-1 指定的位置】那一刀的 contracts 表注写着:
--   「第 4 刀的指数挂钩定价应当落成第四个兄弟(建议 contract_pricing_terms,
--     同样以 contract_id 为键)」,并且刻意**不**把定价的列加在 contracts 那一行上
--   —— 那正是本刀要迁走的形状。本刀照办,没有改那个判断。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这张表装的是【条款】,而条款与【每一笔的谈判】是两件事】(§6,Tim 2026-08-29)
--
--   § 6.1 基准月由哪个事件定义 → **逐合同不同**,是一条合同条款  → base_event(在这里)
--   § 6.3 计价系数从哪来       → **写在合同里**                  → payable_pct(在这里)
--   § 6.2 暂定价怎么定         → **逐笔谈**,不设固定折扣,
--                                 **也不设合同级默认值**          → ★ 不在这里 ★
--
-- ★★【这张表【没有】暂定价那一列,而那个缺席是本表最要紧的一件事】★★
--   §6 第 2 条裁定得很干脆:暂定价是**那一笔交易本身**的属性,不是条款,
--   **而且没有默认值可猜** —— 成交时没谈暂定价,就按名拒,不要替人填一个折扣。
--   在这里加一列 `default_provisional_pct`,哪怕留空,都会变成一个**看起来该填的格子**;
--   而一旦有人填了它,「逐笔谈」就在事实上变成了「合同级默认值」——
--   **正是那条裁定明说不要的东西**。所以这一列不存在,理由写在这里,
--   免得下一个人把它当成遗漏补上。
--
-- 【为什么是逐元素一行】一份合同对镍和钴的计价系数通常不同,而
--   pricing_formula_metals 早就是这个形状(每种金属一行、各带 payable_pct)——
--   跟着既有形状走,而不是发明第二种。
--
-- 【它【不】表达什么,而这些是【没人裁过】,不是漏了】
--   · **按料号分别定价**:同一份合同下不同物料用不同系数 —— 没有人裁过,
--     而猜一个粒度出来会把一个待答的问题伪装成已实现的功能。今天是
--     (合同 × 元素)一行,要更细,先要一次裁定。
--   · **采购侧**:§9 明说「采购侧要不要也用指数联动,本文件没有答案,
--     需要 Tim 说明」。所以本刀**只做卖方向**,而且刻意**不**去扩
--     pricing_term_commitments(那是买方向的承诺表)—— 扩它等于**替 Tim 把
--     那个问题答了**,而一条被暗示的裁定比一个敞着的问题坏。
--

CREATE TABLE public.contract_pricing_terms (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 与 contract_grade_specs.metal / assay_result_metals.metal 同一个字典
    metal        text NOT NULL REFERENCES public.substances (code),
    -- ── §6.1:哪个事件定义基准月 M ── 逐合同不同,所以它是一列,不是一个全局设定
    base_event   text NOT NULL
                 CHECK (base_event IN ('shipment', 'arrival', 'assay_complete')),
    -- ── M+n 的 n ── M+1 → 1,M+3 → 3。允许 0(= 基准月本身,现实中确有这么写的)
    qp_months    integer NOT NULL CHECK (qp_months >= 0 AND qp_months <= 12),
    -- ── 用哪一条指数序列 ── §6 要求算的是"那个市场"的均价,所以它必须具名
    index_code   text NOT NULL REFERENCES public.metal_price_indices (code) ON DELETE RESTRICT,
    -- ── §6.3:计价系数,写在合同里 ── 买方只按含量的一定比例付钱
    payable_pct  numeric NOT NULL CHECK (payable_pct > 0 AND payable_pct <= 100),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    -- 同一份合同同一种元素只规定一次 —— 否则"哪一条说了算"又变成按写入顺序破平局
    -- (CONTRACT-1 的 fu1 为这件事付过一次账,那次是 NULL ≠ NULL;
    --  这里两列都 NOT NULL,所以一条普通的 UNIQUE 就咬得住)
    CONSTRAINT contract_pricing_terms_one_per_metal UNIQUE (contract_id, metal)
);

CREATE INDEX idx_contract_pricing_terms_contract ON public.contract_pricing_terms (contract_id);

ALTER TABLE public.contract_pricing_terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract pricing terms select by owner permission"
    ON public.contract_pricing_terms AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract pricing terms write by owner permission"
    ON public.contract_pricing_terms AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_pricing_terms IS
    'PRICE-1:指数挂钩定价的条款 —— **合同的第四个兄弟子表**,位置是 CONTRACT-1 的 contracts 表注指定的(定价的列**不**加在 contracts 那一行上,那正是本刀要迁走的形状)。装的是【条款】:base_event(§6.1 基准月由哪个事件定义 —— **逐合同不同**)与 payable_pct(§6.3 计价系数 —— **写在合同里**),外加 M+n 与指数序列。★★**它没有暂定价那一列,而那个缺席是本表最要紧的一件事**★★:§6 第 2 条裁定暂定价**逐笔谈**、不设固定折扣、**也不设合同级默认值** —— 在这里加一列哪怕留空,都会变成一个看起来该填的格子,而一旦有人填了它,「逐笔谈」在事实上就变成了「合同级默认值」,正是那条裁定明说不要的东西。**逐元素一行**,跟 pricing_formula_metals 既有形状走。★**它不表达什么,而这些是没人裁过、不是漏了**★:按料号分别定价(粒度没人裁过);**采购侧** —— §9 明说采购侧要不要用指数联动「本文件没有答案,需要 Tim 说明」,所以本刀只做卖方向,并**刻意不扩 pricing_term_commitments**(买方向的承诺表),因为扩它等于**替 Tim 把那个问题答了**,而**一条被暗示的裁定比一个敞着的问题坏**。';

COMMENT ON COLUMN public.contract_pricing_terms.base_event IS
    'PRICE-1:哪个事件定义基准月 M —— 发货 / 到货 / 化验完成。**§6.1 裁定它逐合同不同**,所以它是合同上的一列,**不是一个全局设定**。它也正是 known-issues 里数量承诺那一条在等的同一个判断(「跨月的一船算哪个月」)—— 两处问的是同一件事,分开裁会裁出两个口径。';

COMMENT ON COLUMN public.contract_pricing_terms.qp_months IS
    'PRICE-1:M+n 的 n。M+1 → 1,M+3 → 3;**允许 0**(= 基准月本身,现实中确有这么约的)。计价期 = 基准月往后第 n 个整月的【自然月首尾】,由 quotational_period() 算,不在这里存 —— 存下来就是同一个事实的第二份,而它会与 base_event 漂开。';

-- ═══ 3. 单据抄下来的那一份,多抄一段计价条款 ═════════════════════════════
-- 【为什么不触发"三件一起"】contract_document_terms **没有** _masked 孪生视图,
-- 也没有列清单 SELECT 授权(实测),所以表级授权自动覆盖后加的列。
-- WO-1a 那一课(列清单 SELECT 不会自动扩展到新列)在这里【不适用】,
-- 而这句话是清点过才写下的,不是假定的。
ALTER TABLE public.contract_document_terms
    ADD COLUMN pricing_terms jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.contract_document_terms
    ADD CONSTRAINT contract_document_terms_pricing_terms_is_array
        CHECK (jsonb_typeof(pricing_terms) = 'array');

COMMENT ON COLUMN public.contract_document_terms.pricing_terms IS
    'PRICE-1:挂上去那一刻抄下来的**计价条款**快照 —— 与 grade_specs 同一形状、同一理由(抄不是引用)。★★**冻结的时刻是【挂接】,不是【下单】**★★:CONTRACT-1 刻意允许**回填挂接**(单据日期落在合同期外不拒,因为回填是正当操作),所以一次事后补挂会把**挂接当时**在效的条款冻上去,而不是下单当天的。**对品位规格这条边不算锋利,对钱锋利** —— 所以 link_document_to_contract 的返回里带 terms_frozen_as_of 与 TERMS_FROZEN_AT_LINK_TIME,/contracts 页也把它印出来,好让挂接的人**当场看见自己冻的是哪一份**。**不要去"修"回填权限** —— 那是 CONTRACT-1 裁过的,它站得住。★**它没有暂定价**★:暂定价逐笔谈(§6.2),不是条款。';

-- ═══ 4. 计价期的首尾(算,不存)══════════════════════════════════════
CREATE OR REPLACE FUNCTION public.quotational_period(p_base_date date, p_qp_months integer)
 RETURNS TABLE(qp_from date, qp_to date)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- PRICE-1:M+n 的计价期 = 基准月往后第 n 个【整月】的自然月首尾。
    -- 【为什么算而不是存】把 qp_from/qp_to 存进 contract_pricing_terms,就是同一个
    -- 事实的第二份,而它会与 base_event / qp_months 漂开(本仓库为"两份实现"付过四次账)。
    SELECT (date_trunc('month', p_base_date) + make_interval(months => p_qp_months))::date,
           (date_trunc('month', p_base_date) + make_interval(months => p_qp_months)
              + interval '1 month' - interval '1 day')::date
    WHERE p_base_date IS NOT NULL AND p_qp_months IS NOT NULL;
$function$;

COMMENT ON FUNCTION public.quotational_period(date, integer) IS
    'PRICE-1:M+n 的计价期 = 基准月往后第 n 个【整月】的自然月首尾。**算,不存** —— 把 qp_from/qp_to 存进 contract_pricing_terms 就是同一个事实的第二份,而它会与 base_event / qp_months 漂开(本仓库为「两份实现在写下来那天一致、之后悄悄分开」付过四次账)。n 允许 0(= 基准月本身)。';

-- ═══ 5. ★ 计价期均价:交易日逐日,缺一天按名拒 ★ ═══════════════════
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
--   QP_DUPLICATE_QUOTE|<idx>|<metal>|<d>     同一天同一指数有多于一条报价
--   QP_QUOTE_MISSING|<idx>|<metal>|<d>       某个交易日没有报价 ← ★ 本刀最要紧的那条
DECLARE
    v_ccy      text;
    v_missing  date;
    v_trading  integer;
    v_quotes   integer;
    v_dup      date;
    v_avg      numeric;
    v_legs     jsonb;
BEGIN
    IF p_index_code IS NULL OR p_metal IS NULL OR p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'QP_ARGUMENTS_REQUIRED';
    END IF;
    IF p_to < p_from THEN
        RAISE EXCEPTION 'QP_RANGE_INVERTED|%|%', p_from, p_to;
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

    -- ── ③ 同一天多于一条报价 ────────────────────────────────────────────────
    -- 【不设 UNIQUE 而在这里查,是因为这条约束属于"这次计价"而不是那张表】
    -- 重复的一天会在均值里被算两次,而那是一次静悄悄的加权。
    SELECT mp.price_date INTO v_dup
      FROM metal_prices mp
      JOIN index_market_calendar c
        ON c.index_code = p_index_code AND c.calendar_date = mp.price_date AND c.is_trading_day
     WHERE mp.metal = p_metal AND mp.deleted_at IS NULL
       AND mp.price_index = p_index_code
       AND mp.price_date BETWEEN p_from AND p_to
     GROUP BY mp.price_date HAVING count(*) > 1
     ORDER BY mp.price_date LIMIT 1;
    IF v_dup IS NOT NULL THEN
        RAISE EXCEPTION 'QP_DUPLICATE_QUOTE|%|%|%', p_index_code, p_metal, v_dup;
    END IF;

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

-- ═══ 6. 挂接时把计价条款一并抄下 ═════════════════════════════════════
-- db/functions/link_document_to_contract.sql
-- CONTRACT-1:把一张单据挂到一份合同上,并**当场把在效条款抄下来**。
--
-- ★★【这支函数就是"登记簿不是文件柜"那句话的实现】★★
--   两条拒绝,而**两条都是【不一致】,不是【政策】**(Tim 2026-08-29 裁定 A1):
--     · CONTRACT_COUNTERPARTY_MISMATCH —— 合同是这家、单据是那家。
--       没有人会"故意"这么挂;这是一次录入错误,拒它不需要任何裁定。
--     · CONTRACT_NOT_ACTIVE —— 一份草稿/已终止的合同不该有新单据挂上来。
--   这正是 AGENTS.md 给 ALLOC_CURRENCY_MISMATCH(不一致 → 该拒)与
--   ALLOC_EXCEEDS(政策 → 先问这条规矩对不对)划的那条线。
--
-- ★【刻意【不】拒的那一条,写在这里而不是留成沉默】★
--   **单据日期落在合同期之外,本函数不拒。** 回填一张早于合同生效日的单据是
--   正当操作;而"能不能背靠一份尚未生效的合同下单"是一个**没有人裁过**的问题。
--   没有裁定就按名拒,买到的是绕过它的办法,不是控制(WHT-1 那条同款)。
--   要改这一条,先要有一次裁定,而不是先加一句 IF。
--
-- ★【抄写与检查在【同一笔事务】里,而那是本表不开 INSERT 策略的理由】★
--   分成两步(先查、再抄)之间那道缝,足够让一份刚被改成 terminated 的合同
--   把条款抄出去。所以两者必须同生共死。

CREATE OR REPLACE FUNCTION public.link_document_to_contract(
    p_document_kind text,
    p_document_id uuid,
    p_contract_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_con      contracts%ROWTYPE;
    v_doc_cp   uuid;
    v_doc_code text;
    v_specs    jsonb;
    v_pricing  jsonb;
BEGIN
    IF p_document_kind IS NULL OR p_document_kind NOT IN ('purchase_order','sales_order') THEN
        RAISE EXCEPTION 'CONTRACT_DOCUMENT_KIND_INVALID|%', COALESCE(p_document_kind, 'null')
          USING HINT = '今天只有采购单与销售单挂得上合同 —— 别的单据要先决定"它算不算在合同之下开出来的"';
    END IF;

    SELECT * INTO v_con FROM contracts WHERE id = p_contract_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND|%', p_contract_id;
    END IF;

    -- 【SECURITY DEFINER 自己查权限,按合同归属那一侧查】
    -- 属主权限绕过 RLS,所以这一句不是礼节。
    IF v_con.customer_id IS NOT NULL THEN
        PERFORM require_permission('module.customers.edit');
    ELSE
        PERFORM require_permission('module.suppliers.edit');
    END IF;

    -- ★ 拒绝一:合同不是 active ★
    IF v_con.status <> 'active' THEN
        RAISE EXCEPTION 'CONTRACT_NOT_ACTIVE|%|%', v_con.code, v_con.status
          USING HINT = '只有生效中的合同才收得下新单据 —— 草稿还没谈定,已终止的不该再长出新单据。要挂上去,先把合同置为 active';
    END IF;

    -- 取单据的对手方与编号
    IF p_document_kind = 'purchase_order' THEN
        SELECT supplier_id, code INTO v_doc_cp, v_doc_code
          FROM purchase_orders WHERE id = p_document_id AND deleted_at IS NULL;
        IF v_doc_code IS NULL THEN
            RAISE EXCEPTION 'PO_NOT_FOUND|%', p_document_id; END IF;
        -- ★ 拒绝二:一张采购单只挂得上【买方】合同 ★
        IF v_con.supplier_id IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_SIDE_MISMATCH|%|%', v_con.code, 'purchase_order'
              USING HINT = '这是一份销售合同(对手方是客户),而你要挂的是一张采购单';
        END IF;
        IF v_doc_cp IS DISTINCT FROM v_con.supplier_id THEN
            RAISE EXCEPTION 'CONTRACT_COUNTERPARTY_MISMATCH|%|%', v_con.code, v_doc_code
              USING HINT = '合同的对手方与单据的对手方不是同一家 —— 这是一次录入错误,不是一条可以斟酌的规矩';
        END IF;
    ELSE
        SELECT customer_id, code INTO v_doc_cp, v_doc_code
          FROM sales_orders WHERE id = p_document_id AND deleted_at IS NULL;
        IF v_doc_code IS NULL THEN
            RAISE EXCEPTION 'SO_NOT_FOUND|%', p_document_id; END IF;
        IF v_con.customer_id IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_SIDE_MISMATCH|%|%', v_con.code, 'sales_order'
              USING HINT = '这是一份采购合同(对手方是供应商),而你要挂的是一张销售单';
        END IF;
        IF v_doc_cp IS DISTINCT FROM v_con.customer_id THEN
            RAISE EXCEPTION 'CONTRACT_COUNTERPARTY_MISMATCH|%|%', v_con.code, v_doc_code
              USING HINT = '合同的对手方与单据的对手方不是同一家 —— 这是一次录入错误,不是一条可以斟酌的规矩';
        END IF;
    END IF;

    -- 已经挂过就按名拒,不悄悄改挂 —— 改挂等于把一张单据当初依据的条款换掉。
    IF EXISTS (SELECT 1 FROM contract_document_terms
                WHERE (p_document_kind = 'purchase_order' AND purchase_order_id = p_document_id)
                   OR (p_document_kind = 'sales_order'    AND sales_order_id    = p_document_id)) THEN
        RAISE EXCEPTION 'DOCUMENT_ALREADY_UNDER_CONTRACT|%', v_doc_code
          USING HINT = '这张单据已经挂在一份合同之下了 —— 改挂会把它当初依据的条款换掉,而那是改历史。要换,先决定已经抄下的那一份怎么办';
    END IF;

    -- ★★ 抄:把在效条款的【值】写下来,不是留一个指针 ★★
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'metal', g.metal, 'material_id', g.material_id,
               'min_pct', g.min_pct, 'max_pct', g.max_pct) ORDER BY g.metal), '[]'::jsonb)
      INTO v_specs
      FROM contract_grade_specs g WHERE g.contract_id = v_con.id;

    -- PRICE-1:计价条款一并抄下来。**同一笔事务、同一个抄写动作** ——
    -- 分成两步就会有一道缝,而一份刚被改过的合同可以从那道缝里把条款抄出去。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'metal', t.metal, 'base_event', t.base_event,
               'qp_months', t.qp_months, 'index_code', t.index_code,
               'payable_pct', t.payable_pct) ORDER BY t.metal), '[]'::jsonb)
      INTO v_pricing
      FROM contract_pricing_terms t WHERE t.contract_id = v_con.id;

    INSERT INTO contract_document_terms (
        purchase_order_id, sales_order_id, contract_id,
        contract_code, contract_title, incoterm, currency, payment_terms_days,
        grade_specs, pricing_terms, linked_by)
    VALUES (
        CASE WHEN p_document_kind = 'purchase_order' THEN p_document_id END,
        CASE WHEN p_document_kind = 'sales_order'    THEN p_document_id END,
        v_con.id,
        v_con.code, v_con.title, v_con.incoterm, v_con.currency, v_con.payment_terms_days,
        v_specs, v_pricing, auth.uid());

    -- 单据那一行也记下它挂在哪 —— 这一列是【导航】,条款仍然读上面那份副本。
    IF p_document_kind = 'purchase_order' THEN
        UPDATE purchase_orders SET contract_id = v_con.id WHERE id = p_document_id;
    ELSE
        UPDATE sales_orders SET contract_id = v_con.id WHERE id = p_document_id;
    END IF;

    RETURN jsonb_build_object(
        'document_kind', p_document_kind, 'document_code', v_doc_code,
        'contract_code', v_con.code,
        'grade_specs_copied', jsonb_array_length(v_specs),
        'pricing_terms_copied', jsonb_array_length(v_pricing),
        -- ★【PRICE-1:把"你冻的是哪一份"当场说出来,不要让人事后才发现】★
        --   回填挂接是**正当的**(CONTRACT-1 裁过,不改),而它的后果是:
        --   冻下来的是【挂接此刻】在效的条款,不是下单那天的。
        --   **对品位规格这条边不算锋利,对钱锋利** —— 所以判词跟着返回值走,
        --   而不是只躺在一句代码注释里。文案在 messages/*.ts,双语,按 locale 选。
        'terms_frozen_as_of', now(),
        'terms_frozen_note_code', 'TERMS_FROZEN_AT_LINK_TIME');
END;
$function$;

COMMENT ON FUNCTION public.link_document_to_contract(text, uuid, uuid) IS
'CONTRACT-1:把一张单据挂到合同上,并**当场把在效条款抄下来**。★**这支函数就是"登记簿不是文件柜"那句话的实现**★:两条拒绝 —— 对手方对不上、合同不是 active —— 而**两条都是【不一致】不是【政策】**(AGENTS.md 给 ALLOC_CURRENCY_MISMATCH 与 ALLOC_EXCEEDS 划的线):没有人会故意把 A 家的单挂到 B 家的合同上。★**刻意不拒的那一条**★:单据日期落在合同期之外【不拒】—— 回填是正当操作,而"能不能背靠未生效的合同下单"没有人裁过,没裁定就按名拒买到的是绕过它的办法。**抄写与检查在同一笔事务里**,这也是 contract_document_terms 不开 INSERT 策略的理由:分两步之间那道缝足够让一份刚被改成 terminated 的合同把条款抄出去。已经挂过按名拒,不悄悄改挂 —— 改挂等于把一张单据当初依据的条款换掉。';

-- ═══ 7. 既有均价那一支:加上"两条规矩不是两份实现"的对称注释 ═══════════════
-- 【为什么它也进这次迁移】函数镜像是 pg_get_functiondef 的逐字节副本,
-- 而注释在函数体里 —— 改了注释就是改了定义,线上不跟着改,check_mirrors 会红。
CREATE OR REPLACE FUNCTION public.calculate_metal_price_from_terms(p_terms jsonb, p_metals jsonb, p_quantity_kg numeric, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ref          date;
    v_index        text;
    v_index_ccy    text;
    v_index_known  boolean;
    v_legs         jsonb;
    v_basis        text;
    v_avg_days     integer;
    v_payables     jsonb;
    v_el           jsonb;
    v_metal        text;
    v_content      numeric;
    v_seen         text[] := ARRAY[]::text[];
    v_payable      numeric;
    v_stated       boolean;   -- ASY-2:本金属在条款里【有没有】被提到
    v_price        numeric;
    v_price_date   date;
    v_from         date;
    v_to           date;
    v_contained    numeric;
    v_payable_kg   numeric;
    v_value        numeric;
    v_lines        jsonb := '[]'::jsonb;
    v_skipped      text[] := ARRAY[]::text[];
    v_unpaid       text[] := ARRAY[]::text[];
    v_gross        numeric := 0;
    v_treatment    numeric;
    v_discount     numeric;
    v_net          numeric;
    v_unit         numeric;
BEGIN
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    v_ref := p_reference_date;
    IF p_terms IS NULL OR jsonb_typeof(p_terms) <> 'object' THEN
        RAISE EXCEPTION 'PRICING_TERMS_INVALID';
    END IF;
    -- METAL-2:条款声明的指数。NULL = 未声明,只看同样未标注指数的行情。
    v_index    := p_terms->>'price_index';
    -- METAL-2:【报价币种没声明就不许算钱】本函数是 USD 进 USD 出(FIN-15 记过:
    -- 换算属于路径,不属于本函数)。一个指数若没声明它按什么货币报价,把它的数字
    -- 当成 USD 就是替这个市场宣称了一件没人说过的事 —— 那与编造一个汇率是同一件事,
    -- 而 THE FX RULE 对编造汇率的答复是:拒绝,并说出缺的是什么。
    -- 未声明指数(v_index IS NULL)的老序列不走这道闸:它按 USD 记了一整年,
    -- 这一点由 metal_prices.price_usd_per_tonne 这个列名本身承担(见迁移抬头)。
    IF v_index IS NOT NULL THEN
        SELECT i.quote_currency, true INTO v_index_ccy, v_index_known
        FROM metal_price_indices i WHERE i.code = v_index AND i.is_active;
        IF NOT COALESCE(v_index_known, false) THEN
            RAISE EXCEPTION 'PRICE_INDEX_UNKNOWN|%', v_index;
        END IF;
        IF v_index_ccy IS NULL THEN
            RAISE EXCEPTION 'INDEX_CURRENCY_NOT_STATED|%', v_index;
        END IF;
    END IF;
    v_basis    := p_terms->>'price_basis';
    v_avg_days := (p_terms->>'average_days')::integer;
    v_payables := COALESCE(p_terms->'payables', '{}'::jsonb);

    -- 2. 数量
    IF p_quantity_kg IS NULL OR p_quantity_kg <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;

    -- 3. 金属清单
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        -- PROC-CLEANUP:【现读字典】。这里原本写死七个码 —— 那是 PROC-4 漏掉的三份之一。
        -- PROC-4 报的"残留 0"只对【约束】成立,它的 S1 没有查函数体。
        -- 后果是具体的:往 substances 加一行之后,外键放行,而这里按 METAL_INVALID 拒 ——
        -- 于是"加一种物质 = 加一行"这句承诺,在这条路上不成立。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;

        v_content := (v_el->>'content_pct')::numeric;
        IF v_content IS NULL OR v_content < 0 OR v_content > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;

        -- 4. 商务条款:条款里没有这个金属 = 完全不计价(payable 0),记入 unpaid_metals。
        --    注意与 skipped 的区别:unpaid 是"没谈价",skipped 是"没行情"。
        -- ASY-2:【条款里没有这个金属】与【条款写明 0%】是两件事,不能都印成 0。
        -- v_stated 把这个区别一路带到输出行:未约定的行 payable/payable_kg/value
        -- 一律给 NULL(界面渲染成"—"),0 从此只属于真的谈成了零的条款。
        -- payable_pct 的 CHECK 是 >= 0,所以"明确 0%"是可表示的、正当的一种条款。
        v_stated := v_payables ? v_metal;
        IF v_stated THEN
            v_payable := (v_payables->>v_metal)::numeric;
        ELSE
            v_payable := 0;
            v_unpaid := v_unpaid || v_metal;
        END IF;

        -- 5. 行情:spot 取参考日之前最近一条;average 取窗口内均值(窗口内无行 → NULL)。
        --
        -- ★★★【PRICE-1:本支的 'average' 与 index_period_average() 是【两条不同的
        --       规矩】,不是同一条规矩的两份实现 —— 不要"顺手"把它们合并】★★★
        --   本支:窗口是 `ref-(avg_days-1) … ref`,一段**回看的滚动窗口**;
        --   **不看任何日历**;把窗口里**碰巧有的那些行**取平均;一行都没有时
        --   把该金属记进 skipped_metals 而**不**中止。
        --   **这样做是对的**,而且是 AGENTS.md 明文维护的裁定:
        --   allocate_processing_costs 走的是**生产**那条路,
        --   「缺一条行情不该让生产停下来」。
        --   index_period_average:窗口是**合同约定的那个自然月**(M+n);
        --   **必须**看 index_market_calendar;要求**每一个交易日都有报价**,
        --   缺一天就 QP_QUOTE_MISSING。
        --   **主语不同**:本支的产出是一个【物理事实的成本摊派】,
        --   那一支的产出是一张【要钱的单据】。生产不能因为缺一条行情而停,
        --   而结算不能带着缺一条行情往下走。
        --   (这段话在 index_period_average.sql 里也有一份,位置对称 ——
        --    会来合并它们的人可能从任何一侧进来。)
        v_price := NULL; v_price_date := NULL; v_from := NULL; v_to := NULL; v_legs := NULL;
        IF v_basis = 'spot' THEN
            -- METAL-3:【读的时候换算,按报价自己那一天】。报价按发布原样存
            -- (SMM 存 CNY),换成本函数的 USD 基准是 metal_quote_to_usd 的事 ——
            -- 一处实现,spot 与 average 共用;缺汇率它自己抛 FX_RATE_MISSING。
            SELECT c.usd, mp.price_date, jsonb_build_array(c.leg)
            INTO v_price, v_price_date, v_legs
            FROM metal_prices mp
            CROSS JOIN LATERAL metal_quote_to_usd(mp.price_usd_per_tonne,
                COALESCE(v_index_ccy, 'USD'), mp.price_date) c
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL AND mp.price_date <= v_ref
              -- METAL-2:只看本条款声明的那个指数。IS NOT DISTINCT FROM 让
              -- 【未声明】只匹配【未标注】,而不是匹配任何一条。
              AND mp.price_index IS NOT DISTINCT FROM v_index
            ORDER BY mp.price_date DESC
            LIMIT 1;
        ELSE
            -- price_from / price_to 报【实际参与均值的行】的日期范围,而不是名义窗口 ——
            -- 结算单据上要能看出这个均价到底由哪几天的行情撑起来。
            -- METAL-3:【每条各按自己那天换算,再取平均】,不是先平均再换 ——
            -- 先平均再换会让窗口内的一次汇率波动污染窗口里的每一天。
            -- v_legs 逐条记下出处,于是这个均价可以被重导出,而不是被相信。
            SELECT avg(c.usd), min(mp.price_date), max(mp.price_date),
                   COALESCE(jsonb_agg(c.leg ORDER BY mp.price_date), '[]'::jsonb)
            INTO v_price, v_from, v_to, v_legs
            FROM metal_prices mp
            CROSS JOIN LATERAL metal_quote_to_usd(mp.price_usd_per_tonne,
                COALESCE(v_index_ccy, 'USD'), mp.price_date) c
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_index   -- METAL-2:同上
              AND mp.price_date BETWEEN (v_ref - (v_avg_days - 1)) AND v_ref;
        END IF;

        -- 无可用行情 → 跳过(贡献 0),记入 skipped_metals;沿用 allocate_processing_costs
        -- 的先例:缺行情从来不是硬错误。
        IF v_price IS NULL THEN
            v_skipped := v_skipped || v_metal;
        END IF;

        -- 6. 逐行数量与金额
        v_contained  := round(p_quantity_kg * v_content / 100.0, 4);
        v_payable_kg := round(v_contained * v_payable / 100.0, 4);
        v_value      := CASE WHEN v_price IS NULL THEN 0
                             ELSE round(v_payable_kg / 1000.0 * v_price, 2) END;
        v_gross := v_gross + v_value;

        -- 缺行情/未计价的金属同样出现在 lines 里(金额 0、价格 NULL)——
        -- 结算单据要能逐项交代,不能让它们凭空消失。
        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal,
            'content_pct', v_content,
            -- 未约定 → NULL("未列明"),而不是 0("谈定不付")。金额同理:
            -- 没有条款算不出金额,没有行情也算不出 —— 两种 NULL 都由界面渲染成"—",
            -- 上方的灰字/琥珀提示分别说明是哪一种。汇总仍按 0 累加(贡献确实为零)。
            'payable_pct', CASE WHEN v_stated THEN v_payable END,
            'contained_kg', v_contained,
            'payable_kg', CASE WHEN v_stated THEN v_payable_kg END,
            'price_index', v_index,
            -- METAL-3:换算出处。CNY 原始数、两条腿的汇率、各自实际取自哪一天、
            -- 以及价种(mid)—— 与 price_history 记 original_price / fx_rate /
            -- rate_as_of / rate_type 是同一套做法:数要能被重导出,而不是被相信。
            'fx_legs', COALESCE(v_legs, '[]'::jsonb),
            'quote_currency', COALESCE(v_index_ccy, 'USD'),
            'price_usd_per_tonne', v_price,
            'price_date', v_price_date,
            'price_from', v_from,
            'price_to', v_to,
            'metal_value_usd', CASE WHEN v_stated AND v_price IS NOT NULL THEN v_value END
        );
    END LOOP;

    -- 7. 汇总
    v_gross     := round(v_gross, 2);
    v_treatment := round(p_quantity_kg / 1000.0 * (p_terms->>'treatment_charge_usd_per_tonne')::numeric, 2);
    v_discount  := round(v_gross * (p_terms->>'flat_discount_pct')::numeric / 100.0, 2);
    v_net       := round(v_gross - v_treatment - v_discount, 2);
    v_unit      := round(v_net / p_quantity_kg, 4);

    RETURN jsonb_build_object(
        'formula_id', (p_terms->>'formula_id')::uuid,
        'formula_code', p_terms->>'formula_code',
        'formula_name', p_terms->>'formula_name',
        'price_index', v_index,
        'price_basis', v_basis,
        'average_days', v_avg_days,
        -- FIN-27:这个数按【哪一份条款】算出来的,以及那份条款的费率本身 ——
        -- 出处要能重导出,就不能只给导出后的金额(FIN-26 的同一条道理)。
        'terms_source', p_terms->>'terms_source',
        'commitment_id', p_terms->>'commitment_id',
        'treatment_charge_usd_per_tonne', (p_terms->>'treatment_charge_usd_per_tonne')::numeric,
        'flat_discount_pct', (p_terms->>'flat_discount_pct')::numeric,
        'reference_date', v_ref,
        'quantity_kg', p_quantity_kg,
        'lines', v_lines,
        'gross_value_usd', v_gross,
        'treatment_usd', v_treatment,
        'discount_usd', v_discount,
        'net_value_usd', v_net,
        'unit_price_usd_per_kg', v_unit,
        -- 低品位料确实可能"不值它的处理费";照实返回,由调用方决定接不接这单。
        'negative_value', (v_net < 0),
        'skipped_metals', to_jsonb(v_skipped),
        'unpaid_metals', to_jsonb(v_unpaid)
    );
END;
$function$;
COMMIT;
