-- db/migrations/2026-08-28-wht1-withholding-tax-on-non-resident-payments.sql
-- ════════════════════════════════════════════════════════════════════════════
-- WHT-1:对非居民付款的预提税(新加坡所得税法 s45 一族)。
--
-- ★【这【不是】GST,而把两者当成一件事是本刀最容易犯的错】★
--   GST 是公司【自己账上】的税:销项收进来、进项要回去,净额与 IRAS 结算。
--   预提税是【别人的钱】:公司欠供应商 10,000,只付出去 8,500,把 1,500 代扣
--   下来替对方交给 IRAS。那 1,500 从来不是公司的成本,也从来不是公司的收入 ——
--   它是一笔【代收代付的负债】,从付款那一刻起挂在 2150 上,直到汇出去为止。
--   于是三件事与 GST 完全不同:① 供应商的账【全额结清】,而银行只走净额;
--   ② 它没有"可抵扣"这一侧;③ 它按【付款月】申报,不按季度。
--
-- ★【3.1 的裁定:它是【债务】的属性,不是【收款人】的,也不是【那笔付款】的】★
--   三个事实住在三个地方,而只有一个地方三者同时到齐:
--     · 收款人的【税务居民身份】—— 供应商的属性,慢变量,凭居民证明书;
--     · 付款的【性质】(利息/特许权使用费/管理费/技术服务费)—— 买的是什么,
--       在这套系统里就是那张费用单;
--     · 【代扣这个动作】—— 发生在付款,而那是钱唯一真正劈开的地方。
--   裁定为【债务】,理由是:它是唯一一个两个事实同时已知【且金额已知】的层级,
--   而 IRAS 的纳税时点是「应付」与「实付」孰早 —— 那是债务的日期,不是现金的日期。
--   居民身份是【前置条件】,在债务产生的那一刻从供应商【抄到】债务上并冻住
--   (与税率在开票时冻在发票行上逐字同一条)。付款只【执行】,永远不能重新裁定。
--
--   【另外两个层级错在哪,写下来因为下一个读的人要遇到的是推理不是结论】
--     · 挂在【那笔付款】上是结构性地错的:一笔付款可以同时结掉一张咨询发票和
--       一张货款发票,而一个按付款走的标志只能给出一个答案;
--     · 挂在【收款人】上也是错的:同一个非居民一月卖货(不代扣)、二月卖咨询
--       (要代扣),一个挂在他头上的答案两个月里必有一个是错的。
--
-- ★【范围:只有 expenses,而另外三条路【按名拒】而不是静默略过】★(A3)
--   · inbound_batches —— 货物,结构性排除:买货从来不触发预提税;
--   · freight_documents —— 【按名拒】。它在等一个判断:收款人是船公司/航空公司
--     (法定豁免)还是提供代理服务的货代(未必豁免)。没有人回答过。
--   · purchase_orders(预付)—— 【按名拒】。它在等的判断是:付给非居民顾问的
--     一笔定金【本身】就是一次代扣事件,发生在任何发票存在之前。
--   两条拒绝各值一行代码,而它们买到的是【这个洞不再是隐形的】。
--
-- ★【为什么 record_expense 的 'paid' 那一支【按名拒】】★(A2)
--   record_expense 的 p_payment_status 【默认就是 'paid'】,而那一支
--   借 6xxx / 贷银行 一步到位 —— 不产生应付、不产生 payments 行、不经过
--   record_payment。于是对非居民当场付清的一笔咨询费会【一分钱都不代扣】,
--   而且是走【默认参数值】进去的:最坏的洞的位置。
--   三种处置里选了【按名拒】:让那一支自己也会代扣,就是把劈账的算术写第二遍,
--   而这个仓库为"两份实现在写下来那天一致"付过四次账(见 AGENTS.md 的预览规则)。
--   代价是真的,而且照直付:对非居民的当场付款要多走一步(先记未付、再付款)。
--   所以那条拒绝【必须说出该怎么走】,不能只说不行 —— 一条不指路的拒绝,
--   在默认路径上就是一条会被绕开的拒绝。记在 docs/known-issues.md,
--   作为一次【买来的成本】,不是一个缺陷。
--
-- NOTE: 本文件是变更记录;安装路径完全走镜像(db/tables、db/functions、db/views)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1 · 科目 2150 —— 代扣未缴的税款
-- ─────────────────────────────────────────────────────────────────────────────
-- 【它是负债,不是成本】这是这一整刀的会计要点:代扣下来的钱从来没有进过公司的
-- 损益。借方是应付账款(供应商的债全额解除),贷方是这里(对 IRAS 的债)。
-- 【is_system = true】remit_wht 与 record_payment 按 code 点名引用它。
-- 【is_monetary = true】它是一笔固定金额的货币性负债。它【不带汇率敞口】——
-- 代扣额一律按付款当日汇率折成本位币入账(IRAS 只收新元),所以重估对它恒为零;
-- 标 true 是因为它【就是】货币性项目,不是因为重估会动它。
INSERT INTO public.accounts (code, name_en, name_zh, account_type, is_active, is_system, is_monetary, is_cash)
VALUES ('2150', 'Withholding Tax Payable', '预提税应付', 'liability', true, true, true, false);

-- 【不给 accounts 加表注释】线上这张表本来就没有表注释,镜像也没有。为一个科目
-- 写一句表级注释会立刻造成镜像漂移,而它要说的话属于这个科目、不属于这张表 ——
-- 所以它写在 db/tables/accounts.sql 那一行的行尾注释里,与其余 34 行同一种写法。

-- ─────────────────────────────────────────────────────────────────────────────
-- 2 · suppliers.tax_residence —— 居民身份是【声明的】,不是从国别推出来的
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.suppliers
    ADD COLUMN tax_residence text
        CHECK (tax_residence IS NULL OR tax_residence IN ('resident', 'non_resident'));

COMMENT ON COLUMN public.suppliers.tax_residence IS
'WHT-1:这一家在【新加坡所得税】上是不是居民。三态,而中间那个是重点:
  · ''resident''      —— 新加坡税务居民,付给他的款不触发预提税;
  · ''non_resident''  —— 非居民,付给他的服务/利息/特许权使用费要代扣;
  · NULL              —— **没有人回答过这个问题**,不是"默认居民"。

★【它【不是】country,而这一条是本列存在的全部理由】★
country 是账单地址;税务居民身份取决于【管理与控制在哪里行使】。
一家在新加坡注册的外国公司分支可以是非居民,一家在境外注册、由新加坡管理的
公司可以是居民。**按国别推居民身份,等于把一个证据问题答成一个地址问题** ——
与 customers.default_tax_code 上那句「尤其不按国别自动推 ZR」逐字同一条理由:
出口零税率取决于出口证据,居民身份取决于居民证明,两者都不取决于地址。
线上实测:唯一一家外国供应商(SUP-2026-0003,CN)是【货物】供应商,
买货从来不触发预提税 —— 也就是说按国别推,第一条推论就会是错的。

★【NULL 【不】按名拒,而这是一个量过成本之后的决定,不是一次退让】★
本列既有 8 行全部为 NULL,不回填 —— 捏造一个居民身份比空白坏(FIN-26)。
真正的问题是:一张【身份未申报】的供应商单据要不要拒?实测代价:
**16 份 fixture 调用 record_expense**,每一份都自建供应商,于是任何形式的
「必须申报」(表上的 NOT VALID CHECK、或函数里的按名拒)都会同时改写 16 个
本刀没写过的文件 —— 而它防的那个场景在线上【一个实例都没有】
(0 家 service_vendor,唯一的外国供应商是买货的)。

所以规矩是【非对称】的,按"这个答案会不会改变结果"来划:
  · tax_residence = ''non_resident''  → 记费用时【必须】回答代扣问题
    (WHT_NATURE_REQUIRED;答"不适用"用 wht_natures 的 ''none'' 那一行,
     它是一个【显式的否】,不是一个空白);
  · tax_residence IS NULL             → 不问,照记 —— 而这个缺口
    **被数出来摆在脸上**:/finance/wht 那一页印着"N 家供应商没有申报税务居民
    身份",N 由页面现查。它是 4.2「具名缺席,不是空白」的一次真用。
  · 显式传了代扣性质、而供应商身份是 NULL → 按名拒
    (WHT_RESIDENCE_NOT_STATED):你在断言要代扣,而收款人根本没被分类过。

【残留的风险,照直写】一家【未申报身份】的非居民服务商,今天可以被记费用、
被付款,而系统一分钱都不会代扣。这是上面那个取舍买来的,不是没想到 ——
按名记在 docs/known-issues.md,返回条件是第一家真实的非居民服务商到场。';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3 · wht_natures —— 付款【性质】字典
-- ─────────────────────────────────────────────────────────────────────────────
-- ★【税率不在这张表上】★ 与 tax_codes / tax_rates 是同一条:税率挂在
--   wht_rates 的生效期间上。这里说的是"这笔款【是什么】",而那决定了适用哪一条
--   法令 —— 一笔管理费与一笔特许权使用费税率不同,而且它们各自的税率会各自变。
CREATE TABLE public.wht_natures (
    code           text PRIMARY KEY,
    name_en        text NOT NULL,
    name_zh        text NOT NULL,
    description_en text,
    description_zh text,
    -- 这一种性质的法令出处。**不是装饰** —— 下一个要核对税率的人从这里开始查。
    statute_ref    text NOT NULL,
    is_active      boolean NOT NULL DEFAULT true,
    sort_order     integer NOT NULL DEFAULT 0
);

ALTER TABLE public.wht_natures ENABLE ROW LEVEL SECURITY;
CREATE POLICY "wht_natures select by permission"
    ON public.wht_natures
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

INSERT INTO public.wht_natures
    (code, name_en, name_zh, description_en, description_zh, statute_ref, is_active, sort_order) VALUES
    -- ★【''none'' 是一个【显式的否】,不是一个占位符】★ 付给非居民的款不一定要代扣
    --   —— 买货就不要。而"不要代扣"这个判断【本身】是一次判断,它要留下痕迹。
    --   没有这一行,记账人表达"这一笔不扣"的唯一方式就是把栏位留空,
    --   于是【想过了并回答否】与【根本没想过】在库里长得一模一样 ——
    --   而这正是本仓库对 NULL 反复说的那句话:NULL 不是一个默认值,
    --   是一个没有人回答过的问题。这一行把"否"从空白里救出来。
    ('none', 'Not subject to withholding', '不适用代扣',
     'A deliberate answer that this payment attracts no withholding tax — for example a purchase of goods from a non-resident. NOT a placeholder for "nobody looked".',
     '一个【显式的判断】:这笔款不触发预提税 —— 例如向非居民买货。它不是"没人看过"的占位符。',
     'Recorded judgement — no statutory provision applies', true, 0),
    ('interest', 'Interest, commission or fee on a loan', '利息/佣金/贷款相关费用',
     'Interest, commission, fee or other payment in connection with any loan or indebtedness.',
     '与任何贷款或债务有关的利息、佣金、费用或其他款项。',
     'ITA s45', true, 10),
    ('royalty', 'Royalty or lump sum for movable property', '特许权使用费',
     'Royalty or other lump sum payment for the use of movable property.',
     '因使用动产而支付的特许权使用费或一次性款项。',
     'ITA s45A', true, 20),
    ('know_how', 'Use of scientific or technical knowledge', '技术/商业知识使用费',
     'Payment for the use of, or right to use, scientific, technical, industrial or commercial knowledge or information.',
     '为使用或有权使用科学、技术、工业或商业知识或信息而支付的款项。',
     'ITA s45A', true, 30),
    ('management_fee', 'Management fee', '管理费',
     'Management fees paid to a non-resident.',
     '支付给非居民的管理费。',
     'ITA s45 / prevailing corporate rate', true, 40),
    ('technical_service_fee', 'Technical assistance or service fee', '技术协助/服务费',
     'Technical assistance and service fees for services rendered in Singapore.',
     '在新加坡境内提供的技术协助与服务费。',
     'ITA s45 / prevailing corporate rate', true, 50),
    ('rent_movable_property', 'Rent for movable property', '动产租金',
     'Rent or other payment for the use of movable property.',
     '为使用动产而支付的租金或其他款项。',
     'ITA s45D', true, 60);

COMMENT ON TABLE public.wht_natures IS
'WHT-1:付款性质字典 —— 一笔付给非居民的款【是什么】,而那决定适用哪一条法令。
**税率不在这里**,它在 wht_rates 上按生效期间挂着(与 tax_codes / tax_rates 同一条)。

★【这张表【少】两种性质,而那是刻意的,不是遗漏】★
【非居民董事酬金】(s45B,24%)与【非居民专业人士】(s45B,毛收入 15%)都是真实
存在的代扣类别,而且都比这里任何一种更常见。它们不在这里,因为**这套系统够不着
它们的收款人**:本刀的债务载体是 expenses,而 expenses 的往来对象是 supplier 或
employee —— 而 employees 【没有】税务居民身份这一列,payroll 那条路更是整条不经过
本刀。种一个系统结构上到不了的性质,是在字典里放一句假话。
两者按名记在 docs/known-issues.md 与 docs/accounting-policies.md,等它们真的到场。

★【这张表里的税率是【法律事实】,而这个仓库无权自己认定它】★
见 wht_rates 的表注释。';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4 · wht_rates —— 税率按【生效期间】挂着,与 tax_rates 逐字同形
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE public.wht_rates (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nature         text NOT NULL REFERENCES public.wht_natures (code),
    rate_pct       numeric(6,3) NOT NULL CHECK (rate_pct >= 0 AND rate_pct <= 100),
    effective_from date NOT NULL,
    effective_to   date,          -- NULL = 至今仍生效
    note           text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT wht_rates_window CHECK (effective_to IS NULL OR effective_to >= effective_from),
    -- 同一种性质同一天不能有两条生效行 —— 否则 wht_rate_for 的答案取决于排序,
    -- 而一个取决于排序的税率不是一个税率(与 tax_rates_one_start 同一条)。
    CONSTRAINT wht_rates_one_start UNIQUE (nature, effective_from)
);

ALTER TABLE public.wht_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "wht_rates select by permission"
    ON public.wht_rates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

INSERT INTO public.wht_rates (nature, rate_pct, effective_from, effective_to, note) VALUES
    -- 【''none'' 的 0% 不是一个税率,是那个显式判断的算术后果】它存在是为了让
    -- wht_rate_for 对每一个在册性质都答得出来 —— 一个"某些性质有率、某些没有"的
    -- 字典,会逼每一个调用方自己写一个特例分支,而那就是第二份实现。
    ('none',                   0.000, '1900-01-01', NULL,
     'Not subject to withholding — 0% is the arithmetic consequence of a recorded judgement, not a statutory rate. Dated from 1900 so the answer never depends on the document date.'),
    ('interest',              15.000, '2007-07-01', NULL,
     'ITA s45 — 15% on the gross payment. SEED BASELINE: the start date is this table''s baseline, not a researched commencement date.'),
    ('royalty',               10.000, '2007-07-01', NULL,
     'ITA s45A — 10% on the gross payment. SEED BASELINE: see the interest row.'),
    ('know_how',              10.000, '2007-07-01', NULL,
     'ITA s45A — 10% on the gross payment. SEED BASELINE: see the interest row.'),
    ('rent_movable_property', 15.000, '2007-07-01', NULL,
     'ITA s45D — 15% on the gross payment. SEED BASELINE: see the interest row.'),
    ('management_fee',        17.000, '2010-01-01', NULL,
     'Prevailing corporate rate, 17% from YA2010. A payment dated before 2010-01-01 refuses by name — the earlier history is deliberately not seeded rather than guessed.'),
    ('technical_service_fee', 17.000, '2010-01-01', NULL,
     'Prevailing corporate rate, 17% from YA2010. Same boundary as management_fee.');

COMMENT ON TABLE public.wht_rates IS
'WHT-1:预提税率按【生效期间】挂在性质上。一次法定调整 = 给旧行封口 + 插一行新的,
不 UPDATE 旧行 —— 那会把历史一起改掉。**没有回退**:某天没有生效税率就按名拒
(WHT_RATE_NOT_FOUND),不取最近的一条、不返回 0。与 tax_rate_for 和 fx_rate_for
逐字同源 —— 编一个税率、编一个汇率,是同一种谎,而且两者都会以"报表算得出来"的
样子通过所有测试。

★★【这张表的【内容】是一项法律事实,而这个仓库【没有】认定它的资格】★★
形状(按日期解析、不回退、一次调整封口加行)是工程判断,已经做完了。
**里面那六个数不是。** 它们按上面 note 里写着的出处种下,而每一行的
"SEED BASELINE" 是一句诚实话:起始日期是这张表的基线,不是查证过的法令生效日。
**在第一笔真实的非居民付款之前,这六行必须由 Tim 或会计师逐行核对。**
核对之前,这套机器会算出数、报得出表、一条错误都不会有 —— 那正是危险所在。
这一条同时写在 docs/accounting-policies.md,那份文件是给公司【外面】的人看的。

【条约(DTA)不在这张表里】双边税收协定可以把这些税率【调低】,而适用与否
取决于对方能不能出具居民证明书。那是【逐笔的判断】,不是一个可以按日期查出来的
标量 —— 所以它是债务上的一个覆盖值 + 一个证明书编号,见 expenses.wht_treaty_ref。';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5 · wht_rate_for(nature, date) —— 与 tax_rate_for 逐字同形
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.wht_rate_for(p_nature text, p_date date)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_rate numeric;
BEGIN
    -- 【SECURITY DEFINER 的权限检查】这支函数按 definer 跑,所以它必须自己问
    -- 调用者是谁 —— 一支不问的 definer 函数就是一条绕过 RLS 的路。
    -- 这个形状在本仓库已经【上线过两次、被闸抓住两次】,不再犯第三次。
    PERFORM require_permission('module.finance.view');
    IF p_nature IS NULL THEN RAISE EXCEPTION 'WHT_NATURE_REQUIRED'; END IF;
    IF p_date IS NULL THEN RAISE EXCEPTION 'WHT_DATE_REQUIRED|%', p_nature; END IF;
    IF NOT EXISTS (SELECT 1 FROM wht_natures WHERE code = p_nature) THEN
        RAISE EXCEPTION 'WHT_NATURE_UNKNOWN|%', p_nature;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM wht_natures WHERE code = p_nature AND is_active) THEN
        RAISE EXCEPTION 'WHT_NATURE_INACTIVE|%', p_nature;
    END IF;
    SELECT r.rate_pct INTO v_rate FROM wht_rates r
     WHERE r.nature = p_nature
       AND p_date >= r.effective_from
       AND (r.effective_to IS NULL OR p_date <= r.effective_to);
    IF v_rate IS NULL THEN
        -- 【与 FX、与 GST 同一条】没有那一天的税率就拒绝,不假设、不取最近的一条。
        RAISE EXCEPTION 'WHT_RATE_NOT_FOUND|%|%', p_nature, p_date;
    END IF;
    RETURN v_rate;
END;
$function$;

COMMENT ON FUNCTION public.wht_rate_for(text, date) IS
'WHT-1:按【债务自己那一天】解析付款性质的法定预提税率。没有那一天的税率就按名拒
(WHT_RATE_NOT_FOUND),不取最近的一条、不回退、不返回 0 —— 与 tax_rate_for 和
fx_rate_for 是同一条规矩的第三个实例。**照抄的是形状,不是代码**:它与 tax_rate_for
读的是两张不同的表、答的是两个不同的问题,共用一份实现会让 GST 的一次改动
悄悄改掉预提税的答案。';


-- ─────────────────────────────────────────────────────────────────────────────
-- 5b · journal_entries.source_type 认得汇款这一种分录
-- ─────────────────────────────────────────────────────────────────────────────
-- 【为什么要新增一种,而不是记成 'payment'】'payment' 是【收付供应商/客户】那一族,
-- 而 ap_open_items、bank 对账、现金流量表都按 source_type 分辨一笔钱是干什么的。
-- 一笔给 IRAS 的汇款混进 'payment',会在那三处各自变成一件它不是的事。
ALTER TABLE public.journal_entries DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries ADD CONSTRAINT journal_entries_source_type_check
    CHECK (source_type = ANY (ARRAY['manual'::text, 'purchase'::text, 'sale'::text,
        'processing_cost'::text, 'allocation'::text, 'stocktake'::text, 'writeoff'::text,
        'payment'::text, 'fx'::text, 'expense'::text, 'prepayment'::text, 'payroll'::text,
        'transfer'::text, 'revaluation'::text, 'depreciation'::text, 'asset_disposal'::text,
        'year_close'::text, 'freight'::text, 'invoice'::text, 'shipment'::text,
        'credit_note'::text, 'wht_remittance'::text]));

-- ─────────────────────────────────────────────────────────────────────────────
-- 6 · expenses —— 债务【自己】带着这次代扣的裁定,冻住
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.expenses
    ADD COLUMN wht_payee_residence text
        CHECK (wht_payee_residence IS NULL OR wht_payee_residence IN ('resident', 'non_resident')),
    ADD COLUMN wht_nature       text REFERENCES public.wht_natures (code),
    ADD COLUMN wht_rate_pct     numeric,
    ADD COLUMN wht_amount_ccy   numeric NOT NULL DEFAULT 0,
    ADD COLUMN wht_treaty_ref   text;

-- 【四列是一件事,不是四件】—— 逐字照着上面 expenses_tax_shape 那条写。
-- 最后那个合取项是承重的:一次代扣裁定只能存在于【当时收款人是非居民】的债务上。
-- 少了它,一张写着 resident 却带着税率的费用单在库里是合法的,而它算得出数。
ALTER TABLE public.expenses
    ADD CONSTRAINT expenses_wht_shape CHECK (
        (wht_nature IS NULL     AND wht_rate_pct IS NULL     AND wht_amount_ccy = 0)
     OR (wht_nature IS NOT NULL AND wht_rate_pct IS NOT NULL AND wht_amount_ccy >= 0
         AND wht_payee_residence = 'non_resident'));

COMMENT ON COLUMN public.expenses.wht_payee_residence IS
'WHT-1:**这笔债务产生的那一刻,收款人的税务居民身份**。它是从
suppliers.tax_residence 【抄】过来并冻住的一份,不是一个指向那张表的引用。

【为什么抄而不是查】与 FIN-27 把计价条款抄到承诺记录上、与 GST-2 把税率冻在
发票行上,是同一条:供应商日后改了居民身份(他确实可能改 —— 管理与控制迁走了),
不能倒过来改变一张已经记下的债务该不该代扣。查一次现在的身份,等于让历史随
主数据漂移,而且没有任何东西会说它变了。

【它是 3.1 那条裁定的物证】居民身份是【收款人】的前置条件,代扣与否是【债务】的
属性 —— 这一列就是前者变成后者的那一步。';

COMMENT ON COLUMN public.expenses.wht_nature IS
'WHT-1:这笔款在预提税上【是什么】(wht_natures.code)。NULL = 这张单不代扣。
【NULL 有两种来路,而它们在这一列上分不开,这是刻意的】① 收款人是居民,问题不成立;
② 收款人是非居民而记账人显式回答了"这一笔不代扣"。两者在账上的后果完全相同
(不扣),而把它们分成两个值会逼每一张居民供应商的费用单去回答一个不适用的问题。
真正不许发生的是【第三种】:非居民 + 没有人回答过 —— 而那一种到不了这里,
record_expense 在写之前就按名拒了(WHT_NATURE_REQUIRED)。';

COMMENT ON COLUMN public.expenses.wht_rate_pct IS
'WHT-1:适用税率,按【这张单自己的日期】从 wht_rate_for 解析出来并冻住。
条约减免时这里存的是【减免后】的税率,而 wht_treaty_ref 存那份居民证明书的编号 ——
两者要么都有、要么都没有(record_expense 里的 WHT_TREATY_REF_REQUIRED)。
【为什么不存法定税率再存一个减免值】读的人要的是"这张单扣多少",而两个数字
必须相减才得到答案的设计,会在某一天被人减错方向。法定那一个查得回来:
wht_rate_for(wht_nature, expense_date)。';

COMMENT ON COLUMN public.expenses.wht_amount_ccy IS
'WHT-1:**这张单【全额结清】时会代扣的总额**,单据币种。它是一个【预期值】,
不是账上的数 —— 真正的代扣发生在付款那一刻,按【实付的那一部分】乘税率算
(record_payment),因为法定义务是"就你付出去的那部分代扣"。
于是部分付款只扣部分,而全额付清时 Σ 各次代扣【恰好】等于这一列 ——
fixture 142 的 D 臂钉的就是这条等式。
【为什么还要存它】屏幕要在付款【之前】说得出"这张单会扣多少",而一个要靠
页面自己乘一遍才知道的数,就是第二份实现(AGENTS.md 的预览规则,已犯四次)。';

COMMENT ON COLUMN public.expenses.wht_treaty_ref IS
'WHT-1:主张税收协定(DTA)减免时,那份【居民证明书】(Certificate of Residence)的
编号。非空 ⇔ wht_rate_pct 低于当天的法定税率。

★【为什么减免是一个【要出示证据的覆盖值】,不是一张可以查的表】★
协定税率取决于:对方是不是缔约国居民、这笔款在协定里落在哪一条、以及他能不能
出具居民证明书。前两件在法条里,第三件【在对方手上】—— 没有证明书,IRAS 按
法定税率征,协定写什么都不作数。所以这不是一个"按国别 + 性质"查得出来的标量,
而是一次逐笔的判断,必须留下它凭什么成立的痕迹。
**这个仓库不判断协定适不适用**,它只保证:低于法定就必须说出凭据,而且
永远不许高于法定(WHT_TREATY_RATE_ABOVE_STATUTORY)。判断是人的。';

-- ─────────────────────────────────────────────────────────────────────────────
-- 7 · payment_allocations —— 这一条核销里,有多少【没有付出去】
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.payment_allocations
    ADD COLUMN withheld_pay  numeric NOT NULL DEFAULT 0 CHECK (withheld_pay >= 0),
    ADD COLUMN withheld_base numeric NOT NULL DEFAULT 0 CHECK (withheld_base >= 0);

COMMENT ON COLUMN public.payment_allocations.withheld_pay IS
'WHT-1:这一条核销里【代扣下来、没有付出去】的部分,以【付款币种】计。

★【它是这一整刀的结构核心,而它【不改】allocated_pay 的含义】★
FIN-18 给 allocated_pay 定的意思是"本条核销消耗掉多少付款币种",并且明写了
挂账余额 = payments.amount_ccy − Σ allocated_pay。代扣把那条等式变成:
    挂账余额 = payments.amount_ccy − Σ (allocated_pay − withheld_pay)
**改的是等式,不是 allocated_pay 的定义** —— 因为供应商的债确实按全额解除了,
allocated_pay 说的正是那个全额。把它偷偷改成净额,会让 FIN-18 那段注释
从此说谎,而且已实现汇兑(7100)会跟着错。

【为什么是每条核销一个数,不是每笔付款一个数】一笔付款可以同时结掉一张要代扣的
咨询发票和一张不代扣的货款发票。挂在付款上就只能给出一个答案 —— 那正是 3.1
裁定里"付款层是结构性地错的"那句话,在列上的样子。';

COMMENT ON COLUMN public.payment_allocations.withheld_base IS
'WHT-1:同一笔代扣,折成本位币 —— 按【付款当日】的汇率,不是单据入账汇率。
理由与预付(1300)那一条相同:代扣是【今天新产生的一笔对 IRAS 的负债】,
不是在解除一笔旧的,所以它按今天的口径入账。两者之差正是已实现汇兑,
而这一列站在哪一边,决定了 7100 算得对不对。
IRAS 只收新元,所以这一列才是【要汇出去的那个数】;withheld_pay 只是现金算术。';

-- ─────────────────────────────────────────────────────────────────────────────
-- 8 · wht_remittances —— 汇款是一件【发生过的事】,只可追加
-- ─────────────────────────────────────────────────────────────────────────────
-- ★【与 gst_periods 【不同】的一件事,而这个区别是本表的形状】★
--   GST 要先 open_gst_period 才能申报。这里【没有】"打开一期"这个动作:
--   一个月是不是欠着预提税,是从【已经发生的代扣】推出来的,不需要谁先声明。
--   于是"没有人开这一期"这种失败模式在结构上不存在。
--   本表只记【已经汇出去的】—— 这正是 AGENTS.md 那条
--   「权利是推导出来的,消耗是记录下来的」被【正着】用了一次:
--   欠多少(推导) vs 汇了多少(记录),而重建一个空库时两边同时为零,不产生
--   那条规矩警告的不对称。
CREATE TABLE public.wht_remittances (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code             text NOT NULL UNIQUE,        -- 'WHT-2026-08',补汇为 'WHT-2026-08-2'
    -- 这一笔汇的是【哪一个代扣月】的税。它与 remitted_on 通常差一个月,那是设计:
    -- 当月代扣的税,次月 15 日前申报并缴纳(与 CPF 次月 14 日同一种形状)。
    period_month     date NOT NULL,               -- 当月 1 号
    remitted_on      date NOT NULL,               -- 实际付出去的那一天
    amount_base      numeric NOT NULL CHECK (amount_base > 0),
    -- IRAS S45 电子申报的回执/参考号。**必填** —— 一笔说不出参考号的汇款,
    -- 日后对着 IRAS 无从交代(与 gst_periods.filed_reference 同一条理由,
    -- 只是那一条允许空,而这里不允许:那边"申报"与"缴款"是两件事,这里是一件)。
    filed_reference  text NOT NULL,
    journal_entry_id uuid NOT NULL REFERENCES public.journal_entries (id),
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    CONSTRAINT wht_remittances_month_is_first CHECK (period_month = date_trunc('month', period_month)::date),
    -- 汇款日不能早于它所属的那个月 —— 还没发生的代扣汇不出去。
    CONSTRAINT wht_remittances_after_period CHECK (remitted_on >= period_month)
);

CREATE INDEX idx_wht_remittances_month ON public.wht_remittances (period_month);

-- 只可追加:一次汇款是一件发生过的事。**改正的走法是冲销那张分录**,
-- 而不是改这一行 —— 见 wht_liability_by_month 的视图注释:已汇金额是从
-- 【总账】读的,所以冲销分录会让这一笔自动不作数,不需要在这里标任何状态。
CREATE OR REPLACE FUNCTION public.guard_wht_remittance_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'WHT_REMITTANCE_IMMUTABLE|%', COALESCE(OLD.code, NEW.code);
END;
$function$;

CREATE TRIGGER trg_wht_remittances_append_only
    BEFORE UPDATE OR DELETE ON public.wht_remittances
    FOR EACH ROW EXECUTE FUNCTION public.guard_wht_remittance_append_only();

ALTER TABLE public.wht_remittances ENABLE ROW LEVEL SECURITY;
CREATE POLICY "wht_remittances select by permission"
    ON public.wht_remittances
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

COMMENT ON TABLE public.wht_remittances IS
'WHT-1:一次向 IRAS 的预提税汇款,只可追加。**没有"打开一期"这个动作** ——
欠多少是从已经发生的代扣【推导】出来的,汇了多少是【记录】下来的。
同一个月可以有多行(补汇):一笔补汇是【第二次汇款】,不是对第一次的更正,
所以它是新的一行而不是一个 superseded 标志。
真要更正,冲销那张分录 —— 已汇金额从总账读,冲销会让它自动不作数。';

-- ─────────────────────────────────────────────────────────────────────────────
-- 9 · wht_liability_by_month —— 欠多少 / 汇了多少 / 什么时候到期
-- ─────────────────────────────────────────────────────────────────────────────
-- ★【两侧读的是两个【不同】的真源,而这不是不一致,是本视图的判据】★
--   · 【代扣了多少】从总账读,经 journal_activity_lines —— 也就是【不按
--     status='posted' 过滤】。冲销的做法是原分录标 reversed + 过一张等额反向的
--     posted 分录;只留 posted 会丢原件留冲销件,把一对本该抵零的分录算成
--     −原件。这个病在本仓库已经现身【四次】(cash_flow_statement、f5_return、
--     bank_reconciliation_status、preview_revalue_foreign_balances),
--     第三次那一处【在线上错了几个月】,差 USD 1,585.00。这是第五个本该踩中的
--     地方,而它没有踩中,因为规矩写在了 journal_activity_lines 的函数体里。
--   · 【汇了多少】问的是"这一笔汇款还立着吗" —— 那是【单张分录】的死活,
--     而 status='posted' 正是它的正确判据(同上那段注释点名的三处正确用法)。
--   **求和读前者,判死活读后者。** 两句话是同一条规矩的两半,写在这里是因为
--   下一个要在这张视图上加一句过滤的人,就是在这两者之间做选择。
CREATE OR REPLACE VIEW public.wht_liability_by_month
WITH (security_invoker = off) AS
WITH withheld AS (
    -- 代扣发生在【付款】那一刻,所以归属月 = 那张分录的日期所在的月。
    -- ★【判据是"不是汇款",不是"是付款"】★ 写成 source_type = 'payment' 会
    --   把【手工分录】对 2150 的调整整个漏掉 —— 而手工分录是这套系统里一条
    --   真实存在的路(/finance/journal/new)。漏掉的后果不是报错,是这张视图
    --   的合计与 2150 的科目余额【对不上】,而没有任何东西会说它对不上。
    --   取补集之后,下面那条不变量才成立:
    --       Σ 各月 unremitted_base ≡ 2150 的科目余额
    --   fixture 142 的 F 臂断言它 —— 两边来自两条【真正不同】的推导路径
    --   (这张视图 vs balance_sheet),所以它是一条【动得开】的勾稽,
    --   不是 OPS-17 抓到的那种"拿一个数和它自己比"。
    SELECT date_trunc('month', l.entry_date)::date AS period_month,
           SUM(l.credit - l.debit)                 AS withheld_base
      FROM journal_activity_lines('1900-01-01'::date, '2999-12-31'::date, true) l
     WHERE l.account_code = '2150'
       AND l.source_type IS DISTINCT FROM 'wht_remittance'
     GROUP BY 1
), remitted AS (
    -- 【按它自己声明的所属月归集,不按汇款日】—— 八月的税九月汇,
    -- 按汇款日归集会让八月永远欠着、九月永远多汇。
    -- 【这里【就是】status='posted' 正确的那一种用法】问的是"这一笔汇款
    -- 还立着吗" —— 单张分录的死活。冲销一笔汇款,原分录变 reversed,
    -- 这一行就整个掉出来,而它的冲销分录带着同一个 source_type('wht_remittance',
    -- reverse_journal_entry_internal 原样抄),于是也【不会】被上面那半
    -- 当成一笔新的代扣数进去。两半各自正确,合起来这个月的余额干净地回涨。
    SELECT r.period_month,
           SUM(r.amount_base) AS remitted_base
      FROM wht_remittances r
      JOIN journal_entries e ON e.id = r.journal_entry_id
     WHERE e.status = 'posted'          -- ← 单张分录的死活,见上面第二条
     GROUP BY 1
)
SELECT m.period_month,
       COALESCE(w.withheld_base, 0)                                   AS withheld_base,
       COALESCE(r.remitted_base, 0)                                   AS remitted_base,
       COALESCE(w.withheld_base, 0) - COALESCE(r.remitted_base, 0)    AS unremitted_base,
       -- 【次月 15 日】—— 法定期限。与 CPF 的次月 14 日是两个不同的数,
       -- 各自来自各自的法令,不要"顺手统一"。
       (m.period_month + INTERVAL '1 month 14 days')::date            AS due_date,
       ((m.period_month + INTERVAL '1 month 14 days')::date < CURRENT_DATE
        AND COALESCE(w.withheld_base, 0) - COALESCE(r.remitted_base, 0) > 0) AS is_overdue
  FROM (SELECT period_month FROM withheld
        UNION
        SELECT period_month FROM remitted) m
  LEFT JOIN withheld w ON w.period_month = m.period_month
  LEFT JOIN remitted r ON r.period_month = m.period_month;

GRANT SELECT ON public.wht_liability_by_month TO authenticated;

COMMENT ON VIEW public.wht_liability_by_month IS
'WHT-1:每个代扣月欠 IRAS 多少、已汇多少、余额、法定到期日(次月 15 日)。
**属主权限**:它读总账与 wht_remittances 两处,而 invoker 语义会让无权读总账的人
静默少算 —— 少算一笔要汇的税,与 OPS-14 那五处"行悄悄消失"是同一个病。
读者的门在 /finance/wht 那一页与 operations_now 的 wht_due 支上按 permission 判。

【一个月被汇过之后又出现新的代扣,余额会重新变正 —— 那是对的,不是漂移】
补记一张八月的付款,八月就确实又欠了税。视图【分开报】冻下来的与现在算出来的
两个数(remitted_base / withheld_base),不把它们抹平 —— 与 gst_return_boxes
那条"当时报了多少"与"现在算出来多少"是两个问题,逐字同源。';


-- ─────────────────────────────────────────────────────────────────────────────
-- 10 · record_expense —— 债务【自己】带着代扣裁定
-- ─────────────────────────────────────────────────────────────────────────────
-- 【先 DROP:加参数就是换签名,而 CREATE OR REPLACE 会留下一个旧重载】
-- db/preflight_migration.py 对这件事【按名拒】,理由是旧签名会作为镜像看不见的
-- 漂移活下来(FIN-21)。GST-2 加 p_tax_code 时走的就是这一步,照它做。
DROP FUNCTION IF EXISTS public.record_expense(date, text, numeric, text, numeric, text, text, uuid, text, text, jsonb, uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid, p_tax_code text DEFAULT NULL::text, p_wht_nature text DEFAULT NULL::text, p_wht_rate_pct numeric DEFAULT NULL::numeric, p_wht_treaty_ref text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_account    record;
    v_fx         numeric;
    v_amount_base numeric;
    v_bank       text;
    v_expense_id uuid := gen_random_uuid();
    v_year       integer;
    v_seq        integer;
    v_code       text;
    v_je         jsonb;
    v_asset_id   uuid;
    v_append_id  uuid;   -- FA-1a:追加模式的目标资产
    v_target     fixed_assets%ROWTYPE;
    v_asset_code text;
    v_life       integer;
    v_residual   numeric;
    v_in_service date;
    v_poline     record;   -- EQP-1b-ii:这笔支出付的那一条采购单行
    v_poline_po  record;   -- 那一行所属的采购单
    v_billed     text;     -- 该行上已有的、【未冲销的】支出编号
    -- ── GST-2 ────────────────────────────────────────────────────────────
    v_tax_code   text;      -- 解析出来的进项税码(未注册时恒 NULL)
    v_tax_rate   numeric := 0;
    v_tax_ccy    numeric := 0;   -- 本单进项税,【单据币种】
    v_tax_base   numeric := 0;   -- 同上,本位币 —— 落库的那一个
    v_claimable  boolean := false;
    v_sup_default text;
    v_jlines     jsonb;
    v_cost_ccy   numeric;   -- 资本化口径:净额 + 【不可抵】的那笔税
    v_cost_base  numeric;
    -- ── WHT-1 ────────────────────────────────────────────────────────────
    v_residence     text;      -- 收款人【此刻】的税务居民身份,抄一份冻进这张单
    v_wht_nature    text;      -- 这笔款在预提税上是什么('none' = 显式的否)
    v_wht_rate      numeric;   -- 实际适用税率(条约减免后)
    v_wht_statutory numeric;   -- 当天的法定税率 —— 减免的上限
    v_wht_ccy       numeric := 0;  -- 全额结清时会代扣多少(单据币种,预期值)
    v_wht_ref       text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 科目:必须存在、启用,且是 expense 类型(只有 6xxx 是合法开支落点)
    IF p_expense_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;
    SELECT code, is_active, account_type INTO v_account
    FROM accounts WHERE code = p_account_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(p_account_code, '?');
    END IF;
    IF NOT v_account.is_active THEN
        RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code;
    END IF;
    -- FIN-22:资本性支出 —— 科目 1500 与 p_asset【互相要求】。
    --   * 1500 而无 p_asset:这条路上不许出现没有台账行的固定资产借方;
    --   * p_asset 而非 1500:资本标记只有一个落点,别的科目不接受;
    --   * 其余科目照旧只认 expense 类型("只有 6xxx 是合法开支落点"的原规矩)。
    IF p_account_code = '1500' THEN
        IF p_asset IS NULL THEN
            RAISE EXCEPTION 'CAPITAL_REQUIRES_ASSET|1500';
        END IF;
    ELSIF p_asset IS NOT NULL THEN
        RAISE EXCEPTION 'ASSET_REQUIRES_CAPITAL_ACCOUNT|%', v_account.code;
    ELSIF v_account.account_type <> 'expense' THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_EXPENSE|%', v_account.code;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1b-ii:这笔支出付的是【哪一条采购单行】。
    -- 整块只在 p_purchase_order_line 非空时生效 —— 绝大多数支出根本没有采购单
    -- (D1 那个可空就是为它们留的);而运保关税、安装、调试按 D5 挂在【资产】上
    -- 走追加模式,【不带】采购单行。列注释把这两句话写在了数据库里。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_purchase_order_line IS NOT NULL THEN
        SELECT l.id, l.line_no, l.asset_id, l.purchase_order_id
        INTO v_poline
        FROM purchase_order_lines l
        WHERE l.id = p_purchase_order_line;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', p_purchase_order_line;
        END IF;

        -- ── D2:与 apply_prepayment 同形的三条单据守卫 ────────────────────────
        -- 【"存在"= 没有被软删】apply_prepayment 的那句 WHERE 也带着 deleted_at,
        -- 照抄它是刻意的:少了这一句,一张已被软删的采购单照样收得下账单。
        SELECT po.id, po.code, po.supplier_id, po.status, po.approval_status
        INTO v_poline_po
        FROM purchase_orders po
        WHERE po.id = v_poline.purchase_order_id AND po.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PO_NOT_FOUND|%', v_poline.purchase_order_id;
        END IF;
        IF v_poline_po.status = 'cancelled' THEN
            RAISE EXCEPTION 'PO_CANCELLED|%', v_poline_po.code;
        END IF;
        IF v_poline_po.approval_status <> 'approved' THEN
            RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_poline_po.code, v_poline_po.approval_status;
        END IF;

        -- ── D3 上半:这条链接只在【设备行】上成立 ────────────────────────────
        -- 材料行经【收货】计价形成应付(reprice_inbound_batch),而收货量就是
        -- 它的计费上限。让费用单也挂得上去,等于给材料开【第二条计费路】,
        -- 而没有任何东西把这两条对得起来。同一条规矩也在表上(见下面那个触发器)。
        IF v_poline.asset_id IS NULL THEN
            RAISE EXCEPTION 'PO_LINE_NOT_EQUIPMENT|%', v_poline.line_no
              USING HINT = '材料行经收货计价形成应付,不经费用单';
        END IF;

        -- ── D3 下半:支出的资产必须【就是】行上那一台 ────────────────────────
        -- 拆成三种情形分别点名,因为它们的【修法互不相同】。合成一句"资产对不上"
        -- 会把两种根本不是"对不上"的情形也说成对不上 —— 尤其是新建那一支:
        -- 那里的资产是这一刻才生出来的,报一个"你填的 id 与行上的不符"
        -- 会打发人去核对一个一毫秒之前还不存在的 id。
        IF p_asset IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_NOT_CAPITAL|%|%', v_poline.line_no, p_account_code
              USING HINT = '挂在设备行上的支出必须是资本支出:科目 1500 + p_asset';
        END IF;
        IF (p_asset->>'asset_id') IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_CREATES_ASSET|%', v_poline.line_no
              USING HINT = '设备行引用的资产卡【已经存在】(行不创建资产),这笔支出要以追加模式挂上去:p_asset.asset_id';
        END IF;
        IF (p_asset->>'asset_id')::uuid <> v_poline.asset_id THEN
            RAISE EXCEPTION 'EXPENSE_ASSET_MISMATCH|%|%', p_asset->>'asset_id', v_poline.asset_id
              USING HINT = 'B 机器的发票不能记到 A 机器的订单行上';
        END IF;

        -- ── D2 第四条:供应商一致 —— 但先问【有没有供应商】────────────────────
        -- 【这条规矩的主体可以缺席】expenses_counterparty_shape 只对 unpaid 强制
        -- 往来对象;paid 的费用单 supplier_id 合法地为空(线上那 2 笔就是)。
        -- 于是"供应商一致"若直接写成比较,对一半的单据是拿 NULL 去比 ——
        -- 那不是"不一致",是"没人说过"。两件事两个名字。
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_SUPPLIER_NOT_STATED|%', v_poline_po.code
              USING HINT = '挂在采购单行上的支出必须说出开这张票的供应商';
        END IF;
        IF p_supplier_id <> v_poline_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_poline_po.code, p_supplier_id;
        END IF;

        -- ── D4:覆盖推导 —— 一条设备行只报销一次 ─────────────────────────────
        -- 【必须排除已冲销的】一笔冲销掉的支出【没有发生过】,它的行因此重新
        -- 可计费。判据只有一句:status = 'posted'。它站得住,是因为
        -- guard_expense_mutation 只放行 posted→reversed 且同时首挂
        -- reversed_by_expense,并且拒绝一切 DELETE —— 两列永远同步,
        -- 所以 status='reversed' 与 reversed_by_expense IS NOT NULL 是同一件事。
        -- 【这段话原本说"冲销了再记一笔"会把成本记成 170,000 —— EQP-1b-iii 之后
        --   它不再成立,所以就地退休,而不是留在这里骗下一个读它的人。】
        -- 当时(EQP-1b-ii)的实测是:冲销一笔追加模式的资本支出【允许】、分录冲掉、
        -- 而 cost_base 与成本明细原样不动,于是"冲销再记"= 100,000 的机器记成 170,000。
        -- EQP-1b-iii 修好了那一条:冲销现在会把成本退回去,并当场核对
        -- 表头 = 未冲销明细之和。所以【未投用】的机器,"冲销那笔支出再记一笔"
        -- 现在是一条安全的路,消息里也就照直说了。
        -- 【但它只在未投用时安全】资产一旦投用,冲销按名拒
        -- (ASSET_IN_SERVICE_COST_LOCKED),而向下修正一台已投用资产的成本
        -- 今天【没有任何路】—— 记在 docs/known-issues.md,带返回条件。
        -- 消息因此仍然把【改订单】放在前面:发票与估价对不上时,那才是要改的东西。
        -- 【第二层是索引】uq_expenses_live_po_line,谓词与这里逐字相同。
        -- 这里负责【可读】(带上占着这条行的那张单的编号),索引负责【正确】
        -- (并发下两笔同时通过本判据时,只有一笔落得下去)—— invoice_lines 的原话。
        SELECT e.code INTO v_billed
        FROM expenses e
        WHERE e.purchase_order_line_id = p_purchase_order_line
          AND e.status = 'posted'
        LIMIT 1;
        IF v_billed IS NOT NULL THEN
            RAISE EXCEPTION 'PO_LINE_ALREADY_EXPENSED|%|%', v_poline.line_no, v_billed
              USING HINT = '一条设备行只报销一次。若是【订单上的估价】与发票对不上,要改的是订单(改行,不是删行),不是再记一笔';
        END IF;
    END IF;

    -- 2. 金额/币种/汇率(FIN-0:SGD 本位免换算,外币按费用日牌价估值)
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【费用日】的行方卖出价(tt_sell)估值 ——
    -- 应付与开销是我们将来要【向银行买】的外币。当日无牌价即拒(FX_RATE_MISSING)。
    -- 汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, p_expense_date, 'tt_sell');

    -- 3. 支付状态
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;

    IF p_payment_status = 'paid' THEN
        -- paid:银行科目显式给了必须合法;不给按币种默认 —— 映射只有一份
        -- (bank_account_for_currency,bank_native_currency 的逆)
        IF p_bank_account IS NOT NULL THEN
            IF p_bank_account NOT IN ('1000','1010') THEN
                RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
            END IF;
            v_bank := p_bank_account;
        ELSE
            v_bank := bank_account_for_currency(p_currency);
        END IF;
    ELSE
        -- unpaid:必须有在册供应商(它要成为 AP 单据);银行科目必须为空 ——
        -- 传了也直接忽略(挂账时根本没动银行,存下来只会误导)
        -- PAYEE-1a:往来对象【二选一】—— 供应商 或 员工,恰好一个。
        -- 【两个都给是矛盾,不是"取其一"】一笔钱不可能同时欠着两个人;
        -- 悄悄挑一个会让另一个人的账凭空消失,所以按名拒绝。
        IF num_nonnulls(p_supplier_id, p_employee_id) = 0 THEN
            RAISE EXCEPTION 'COUNTERPARTY_REQUIRED_FOR_UNPAID';
        END IF;
        IF num_nonnulls(p_supplier_id, p_employee_id) > 1 THEN
            RAISE EXCEPTION 'COUNTERPARTY_AMBIGUOUS';
        END IF;
        IF p_supplier_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
        END IF;
        IF p_employee_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM employees WHERE id = p_employee_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_employee_id;
        END IF;
        v_bank := NULL;
    END IF;

    -- 4. USD 金额。**p_amount 始终是【不含税净额】** —— 供应商账单上的总额
    --    是净额 + 税,而这一列记的是开支本身的价值。GST 关着时两者相等,
    --    所以这条口径对既有行为是恒等的。
    v_amount_base := round(p_amount * v_fx, 2);

    -- ════════════════════════════════════════════════════════════════════════
    -- 4b. GST-2:进项税码 —— 【供应商默认 + 本单改写】,税率按【费用日】解析。
    -- 【为什么费用日就是税点】进项侧的税点是供应商那张税务发票的日期,
    -- 而 record_expense 的 p_expense_date 记的正是那一天。总账口径与法定口径
    -- 在进项侧本来就重合 —— 所以 F5 的进项侧仍然从总账推导,那不是妥协。
    -- ════════════════════════════════════════════════════════════════════════
    IF gst_registered() THEN
        SELECT default_tax_code INTO v_sup_default FROM suppliers WHERE id = p_supplier_id;
        -- 【没有供应商的 paid 单据必须自己带码】那是合法的一种单据
        -- (线上就有两笔),而它没有可以继承默认的对象 —— 于是要么本单指定,
        -- 要么按名拒。不猜。
        v_tax_code := resolve_tax_code(p_tax_code, v_sup_default, 'input', 'supplier');
        v_tax_rate := tax_rate_for(v_tax_code, p_expense_date);
        v_tax_ccy  := round(p_amount * v_tax_rate / 100.0, 2);
        v_tax_base := round(v_tax_ccy * v_fx, 2);
        SELECT is_claimable INTO v_claimable FROM tax_codes WHERE code = v_tax_code;
    ELSE
        -- 【未注册:与建 GST 之前一模一样】传了码要按名拒,不能悄悄忽略。
        IF NULLIF(btrim(COALESCE(p_tax_code, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'GST_NOT_REGISTERED|%', p_tax_code;
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 4c. WHT-1:预提税 —— **这张单要不要替收款人代扣,以及扣多少**。
    --
    -- ★【这【不是】GST 的第二个实例,两者在这张单上做的是相反的事】★
    --   进项税是【加】在供应商账单上、公司还能要回来的钱;
    --   预提税是【从】要付给供应商的钱里【扣下来】、替他交给 IRAS 的钱。
    --   所以这一段不碰分录:记这张费用单的时候什么都没扣 —— 债是全额的。
    --   代扣发生在【付款】那一刻(record_payment),因为法定义务是就
    --   "你实际付出去的那部分"代扣。这里只把【裁定】冻下来。
    --
    -- 【裁定的三个部件,以及它们各自的来路】
    --   ① 居民身份 —— 从 suppliers.tax_residence 抄一份冻住(见列注释);
    --   ② 性质     —— 由记账人显式回答,'none' 是一个合法且显式的"否";
    --   ③ 税率     —— wht_rate_for(性质, 费用日),条约减免时由本单覆盖并出示凭据。
    -- ════════════════════════════════════════════════════════════════════════
    v_residence  := NULL;
    v_wht_nature := NULLIF(btrim(COALESCE(p_wht_nature, '')), '');
    v_wht_ref    := NULLIF(btrim(COALESCE(p_wht_treaty_ref, '')), '');
    IF p_supplier_id IS NOT NULL THEN
        SELECT tax_residence INTO v_residence FROM suppliers WHERE id = p_supplier_id;
    END IF;

    IF v_wht_nature IS NOT NULL THEN
        -- ── 有人断言这张单要做代扣裁定 ──────────────────────────────────
        -- 【收款人必须是供应商】员工与"只有名字的收款人"都到不了这里:
        -- employees 没有税务居民身份这一列,而 payee_name 是一段自由文本 ——
        -- 对一段文本做税务裁定是没有主语的。两者都是【具名缺席】,记在
        -- docs/known-issues.md,不是靠这里悄悄放过。
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'WHT_PAYEE_NOT_A_SUPPLIER|%', v_wht_nature
              USING HINT = '预提税裁定只能落在一个在册供应商上 —— 员工报销与只有名字的收款人不在本刀范围内';
        END IF;
        IF v_residence IS NULL THEN
            RAISE EXCEPTION 'WHT_RESIDENCE_NOT_STATED|%', p_supplier_id
              USING HINT = '这家供应商还没有申报税务居民身份 —— 先在供应商档案上填,再记这张单';
        END IF;
        IF v_residence <> 'non_resident' THEN
            -- 居民收款人不代扣。悄悄扣 0 会在账上留下一条"想过了"的假痕迹。
            RAISE EXCEPTION 'WHT_PAYEE_IS_RESIDENT|%|%', p_supplier_id, v_wht_nature
              USING HINT = '这家供应商申报的是新加坡税务居民 —— 付给他的款不代扣';
        END IF;
        -- ★【A2:'paid' 那一支按名拒,并且【说出该怎么走】】★
        --   record_expense 的 p_payment_status 默认就是 'paid',而那一支
        --   借 6xxx / 贷银行 一步到位,不产生应付、不经过 record_payment ——
        --   也就是不经过唯一知道怎么劈账的那段代码。让它自己也会劈,
        --   就是把同一份算术写第二遍(AGENTS.md 的预览规则,已犯四次)。
        --   【一条不指路的拒绝,在默认路径上就是一条会被绕开的拒绝】——
        --   所以 HINT 说的是走法,不是"不行"。
        IF p_payment_status = 'paid' THEN
            RAISE EXCEPTION 'WHT_ON_PAID_EXPENSE_UNSUPPORTED|%', v_wht_nature
              USING HINT = '要代扣的费用请先记成【未付】(挂应付),再用付款功能付掉 —— 代扣在付款那一步发生,那里只有一份劈账的实现';
        END IF;

        v_wht_statutory := wht_rate_for(v_wht_nature, p_expense_date);
        IF p_wht_rate_pct IS NULL THEN
            -- 没有主张条约减免:按法定税率。
            IF v_wht_ref IS NOT NULL THEN
                RAISE EXCEPTION 'WHT_TREATY_REF_WITHOUT_RATE|%', v_wht_ref
                  USING HINT = '给了居民证明书编号却没有给协定税率 —— 两者要么都给,要么都不给';
            END IF;
            v_wht_rate := v_wht_statutory;
        ELSE
            IF p_wht_rate_pct < 0 THEN
                RAISE EXCEPTION 'WHT_TREATY_RATE_INVALID|%', p_wht_rate_pct;
            END IF;
            -- 【永远不许高于法定】协定只会调低,不会调高。高于法定的"减免"
            -- 是一个打错的数字,而它会算得出来。
            IF p_wht_rate_pct > v_wht_statutory THEN
                RAISE EXCEPTION 'WHT_TREATY_RATE_ABOVE_STATUTORY|%|%|%',
                    v_wht_nature, p_wht_rate_pct, v_wht_statutory;
            END IF;
            -- 【低于法定必须出示凭据】没有居民证明书,IRAS 按法定税率征,
            -- 协定写什么都不作数 —— 所以少扣的那一部分是公司自己要补的钱。
            IF p_wht_rate_pct < v_wht_statutory AND v_wht_ref IS NULL THEN
                RAISE EXCEPTION 'WHT_TREATY_REF_REQUIRED|%|%|%',
                    v_wht_nature, p_wht_rate_pct, v_wht_statutory
                  USING HINT = '低于法定税率要凭居民证明书(Certificate of Residence)—— 填它的编号';
            END IF;
            v_wht_rate := p_wht_rate_pct;
        END IF;
        -- 【预期值:全额结清时会扣多少】真正的代扣按实付部分算,见 record_payment。
        v_wht_ccy := round(p_amount * v_wht_rate / 100.0, 2);
    ELSE
        -- ── 没有给性质 ──────────────────────────────────────────────────
        IF p_wht_rate_pct IS NOT NULL OR v_wht_ref IS NOT NULL THEN
            RAISE EXCEPTION 'WHT_NATURE_REQUIRED|rate_without_nature'
              USING HINT = '给了协定税率或证明书编号,却没有说这笔款是什么性质';
        END IF;
        -- ★【承重的那一条】★ 收款人【申报过】是非居民,就必须回答这个问题。
        --   答"不适用"用 'none' —— 它是一个显式的否,不是一个空白。
        --   身份为 NULL 时【不问】:那是一个量过成本的取舍,理由整段写在
        --   db/tables/suppliers.sql 的 tax_residence 列注释里,不在这里复述。
        IF v_residence = 'non_resident' THEN
            RAISE EXCEPTION 'WHT_NATURE_REQUIRED|%', p_supplier_id
              USING HINT = '收款人是非居民 —— 说明这笔款的预提税性质;确实不适用就选「不适用代扣」(none),不要留空';
        END IF;
    END IF;

    -- 【资本化口径:不可抵的进项税【是】资产成本的一部分】
    -- 可抵的税要得回来,它从来不是成本;不可抵的税(BL —— 私家车是最典型的
    -- 那一类)要不回来,于是它和买价一样是为了取得这台资产付出去的钱。
    -- 【为什么不在这里按名拒掉 BL + 资本】那会把一个【有确定答案的】会计问题
    -- 说成一个待裁决的问题。ASSET_ALREADY_IN_SERVICE 那条拒绝之所以成立,
    -- 是因为"投用后的追加是资本化改良还是当期费用"真的需要人来判;这一条不需要。
    v_cost_ccy  := round(p_amount    + CASE WHEN v_claimable THEN 0 ELSE v_tax_ccy  END, 2);
    v_cost_base := round(v_amount_base + CASE WHEN v_claimable THEN 0 ELSE v_tax_base END, 2);

    -- 5. 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款编号手法);失败回滚会释放号码。
    v_year := EXTRACT(YEAR FROM p_expense_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE 'EXP-' || v_year::text || '-%';
    v_code := 'EXP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 6. 先过分录(source_id = 预生成的 expense id,无需回填),期间锁在此生效。
    --    paid → 贷银行;unpaid → 贷 2000 应付。行走原币。
    -- ── GST-2:分录的形状 ────────────────────────────────────────────────
    -- 【净额那条腿带税码】F5 的 box5 = Σ(借−贷) FILTER (tax_code IN (TX,ZP,BL)),
    -- 所以它报的是【采购净额】,这正是 IRAS 要的"应税采购总额"。
    v_jlines := jsonb_build_array(
        jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                           'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx,
                           'tax_code', v_tax_code));
    IF v_tax_ccy > 0 THEN
        IF v_claimable THEN
            -- 可抵:税借 1400 进项税 —— box7 就是从这个科目推导的。
            v_jlines := v_jlines || jsonb_build_object('account_code', '1400', 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_tax_ccy, 'fx_rate', v_fx,
                'line_memo', 'input tax ' || v_tax_code);
        ELSE
            -- 【不可抵(BL)不是"没有税",是"有税但要不回来"】那笔税进【开支本身】。
            -- 【这条腿【不带】税码】带上它,box5 报的就成了含税额,而 IRAS 要的是
            -- 采购价值 —— 税码存在的全部理由正是"税率分不开可抵与不可抵"。
            v_jlines := v_jlines || jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_tax_ccy, 'fx_rate', v_fx,
                'line_memo', 'blocked input tax ' || v_tax_code);
        END IF;
    END IF;
    -- 【贷方拆成两条腿,而不是一条总额腿】供应商收的是净额 + 税,但
    -- post_journal_entry 是【逐行】round(原币 × 汇率) 的:一条 round((净+税)×fx)
    -- 的腿与两条 round(净×fx) + round(税×fx) 的借方腿会差一分钱,而那一分钱
    -- 会撞上提交时的借贷平衡触发器。两条腿按构造精确对冲,不靠运气。
    v_jlines := v_jlines || jsonb_build_object(
        'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
        'side', 'credit',
        'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx);
    IF v_tax_ccy > 0 THEN
        v_jlines := v_jlines || jsonb_build_object(
            'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
            'side', 'credit',
            'currency', p_currency, 'amount_ccy', v_tax_ccy, 'fx_rate', v_fx,
            'line_memo', 'GST on ' || v_code);
    END IF;

    v_je := post_journal_entry(
        p_expense_date,
        'Expense ' || v_code || ' ' || p_account_code,
        'expense', v_expense_id,
        v_jlines
    );

    -- 7. 插入开支单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id, employee_id,
                          payee_name, notes, journal_entry_id, created_by,
                          purchase_order_line_id,
                          tax_code, tax_rate_pct, tax_base,
                          -- WHT-1:裁定冻在债务上。居民身份是【抄下来的一份】,
                          -- 不是一个指向 suppliers 的引用 —— 供应商日后迁走管理与
                          -- 控制、身份跟着变,不能倒过来改写一张已经记下的债务。
                          wht_payee_residence, wht_nature, wht_rate_pct,
                          wht_amount_ccy, wht_treaty_ref)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, p_amount, p_currency, v_fx,
            v_amount_base, p_payment_status, v_bank, p_supplier_id, p_employee_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user,
            p_purchase_order_line,
            v_tax_code,
            CASE WHEN v_tax_code IS NULL THEN NULL ELSE v_tax_rate END,
            v_tax_base,
            -- 【只有做过裁定的单据才带身份】没有裁定时这四列全空,与
            -- expenses_wht_shape 那条 CHECK 的第一支逐字对应。居民收款人、
            -- 员工报销、身份未申报 —— 三种情况在这里都是空,而它们的
            -- 【区别】记在别处(拒绝的名字、以及 /finance/wht 数出来的缺口)。
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_residence END,
            v_wht_nature,
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_rate END,
            CASE WHEN v_wht_nature IS NULL THEN 0    ELSE v_wht_ccy END,
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_ref END);

    -- FIN-22:资本行 → 同一事务生成台账。成本 = 本单金额;汇率 = 上面按
    -- 【费用日 = 购置日】取的 tt_sell 牌价 —— 资产是非货币项目,这个汇率
    -- 定格成本,永不重译(表注有言,重估扫不到 1500/1510)。
    IF p_asset IS NOT NULL THEN
        -- ── FA-1a:同一扇门,两种模式 ────────────────────────────────────────
        -- 【为什么不开第二个函数】1500 ↔ p_asset 的互相要求是这条路上唯一的
        -- 不变量:没有台账行的 1500 借方进不来,资本标记也落不到别的科目上。
        -- 再开一个 add_cost_to_asset() 等于开第二扇门,而那个不变量只守得住
        -- 第一扇 —— 与"单据不该有第二个写法"同一条(so_issues / approval_log)。
        -- 所以追加走【同一个函数】:p_asset 带 asset_id 就是追加,不带就是新建。
        v_append_id := (p_asset->>'asset_id')::uuid;

        IF v_append_id IS NOT NULL THEN
            -- ── 追加成本(运费、关税、安装调试)──────────────────────────
            SELECT * INTO v_target FROM fixed_assets WHERE id = v_append_id FOR UPDATE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ASSET_NOT_FOUND|%', v_append_id;
            END IF;
            -- 【投用之后成本就冻住了】投用那一刻起折旧按它算;再往上加钱,
            -- 已经提过的那几期就全错了 —— 而它们已经过账,可能已经锁进期间。
            -- 投用后的追加是一次【会计判断】(资本化改良 vs 当期费用),
            -- 不是这条路顺手做得了的事,所以按名拒,把那个判断交还给人。
            IF v_target.in_service_date IS NOT NULL THEN
                RAISE EXCEPTION 'ASSET_ALREADY_IN_SERVICE|%|%', v_target.code, v_target.in_service_date;
            END IF;
            IF v_target.status <> 'active' THEN
                RAISE EXCEPTION 'ASSET_DISPOSED|%', v_target.code;
            END IF;

            -- 每一笔追加带【自己的】三件套:原币金额、它自己那天的汇率、本位币额。
            -- 表头那三列是【第一笔】的(购置那一笔),不是合计 —— 合计只有
            -- cost_base 一个数,而各笔的原币可以不同(进口机器 USD、本地运费 SGD)。
            INSERT INTO fixed_asset_cost_entries
                (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
            VALUES (v_append_id, v_expense_id, v_cost_ccy, p_currency, v_fx, v_cost_base, v_user);

            UPDATE fixed_assets
               SET cost_base = cost_base + v_cost_base
             WHERE id = v_append_id;

            RETURN jsonb_build_object(
                'expense_id', v_expense_id,
                'asset_id', v_append_id, 'asset_code', v_target.code,
                'asset_mode', 'append',
                'journal_entry_id', (v_je->>'entry_id')::uuid,
                'journal_code', v_je->>'code',
                'code', v_code);
        END IF;

        -- ── 新建(FIN-22 起的原样路径)──────────────────────────────────────
        -- 【两扇建卡的门,而【两扇都不是遗留】—— EQP-1c-a 记在这里,免得下一个
        --   读到 create_fixed_asset 的人以为这一支该被删掉。】
        --   * 这一支(卡与成本【同时】诞生):一台【没有采购单、当场买断】的机器。
        --     那件事的真实形状就是"一张发票同时带来这台机器和它的成本",
        --     硬要拆成两步反而是编造一个不存在的中间状态。
        --   * create_fixed_asset(卡先诞生、成本后到):设备采购的常态 ——
        --     先下单(而采购单行必须引用一张【已存在】的卡,EQP-1a),
        --     后开票。发票经【追加】模式落到那张卡上。
        --   判据一句话:**这台机器在拿到它的成本之前,需不需要先被别的单据引用?**
        --   需要 → create_fixed_asset;不需要 → 这一支。
        IF COALESCE(p_asset->>'description', '') = '' THEN
            RAISE EXCEPTION 'ASSET_DESCRIPTION_REQUIRED';
        END IF;
        v_life := (p_asset->>'useful_life_months')::integer;
        IF v_life IS NULL OR v_life <= 0 THEN
            RAISE EXCEPTION 'ASSET_LIFE_INVALID|%', COALESCE(p_asset->>'useful_life_months', '?');
        END IF;
        v_residual := COALESCE((p_asset->>'residual_base')::numeric, 0);
        IF v_residual < 0 OR v_residual >= v_cost_base THEN
            RAISE EXCEPTION 'ASSET_RESIDUAL_INVALID|%|%', v_residual, v_cost_base;
        END IF;
        v_in_service := (p_asset->>'in_service_date')::date;
        IF v_in_service IS NOT NULL AND v_in_service < p_expense_date THEN
            RAISE EXCEPTION 'ASSET_IN_SERVICE_BEFORE_ACQUISITION|%|%', v_in_service, p_expense_date;
        END IF;

        v_asset_id := gen_random_uuid();
        -- EQP-1c-a:取号提成 next_fixed_asset_code(),两扇门共用一个号段。
        -- 【行为逐字不变】它就是原来这四行:同一把咨询锁(键也是按年拼的
        -- 'fixed_asset_code_'||year)、同一个"当年最大号 + 1"。提出来是因为
        -- 现在有【两扇】建卡的门,而两份同样的取号逻辑迟早会漂开。
        v_asset_code := next_fixed_asset_code(p_expense_date);

        INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date,
                                  cost_ccy, currency, fx_rate, cost_base, useful_life_months,
                                  residual_base, depreciation_account_code, expense_id, notes, created_by)
        VALUES (v_asset_id, v_asset_code, p_asset->>'description',
                COALESCE(p_asset->>'category', 'equipment'),
                p_expense_date, v_in_service,
                v_cost_ccy, p_currency, v_fx, v_cost_base, v_life,
                v_residual, COALESCE(p_asset->>'depreciation_account_code', '6700'),
                v_expense_id, p_asset->>'notes', v_user);

        -- 【第一笔也进明细表】否则"这台机器的成本由哪几笔构成"对第一笔要查
        -- expenses、对后续几笔要查明细表 —— 两处读法,迟早各说各话。
        INSERT INTO fixed_asset_cost_entries
            (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
        VALUES (v_asset_id, v_expense_id, v_cost_ccy, p_currency, v_fx, v_cost_base, v_user);
    END IF;

    RETURN jsonb_build_object(
        'expense_id', v_expense_id,
        'asset_id', v_asset_id, 'asset_code', v_asset_code,
        'code', v_code,
        'amount_base', v_amount_base,
        'journal_code', v_je->>'code',
        'payment_status', p_payment_status,
        -- WHT-1:把裁定回给调用方,让屏幕说得出"这张单付的时候会扣多少" ——
        -- 而不是让页面自己再乘一遍(那就是第二份实现)。
        'wht_nature', v_wht_nature,
        'wht_rate_pct', CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_rate END,
        'wht_amount_ccy', CASE WHEN v_wht_nature IS NULL THEN 0 ELSE v_wht_ccy END,
        'currency', p_currency
    );
END;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11 · record_payment —— 债全额解除,钱只走净额,差额成为对 IRAS 的负债
-- ─────────────────────────────────────────────────────────────────────────────
-- 签名不变(代扣率从债务上读,不由调用方递入),所以只 REPLACE。

CREATE OR REPLACE FUNCTION public.record_payment(p_direction text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_payment_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb, p_counterparty_kind text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind text;
    v_user         uuid := auth.uid();
    v_base         text;   -- OPS-8:本位币从 currencies.is_base 读
    v_date         date;
    v_fx           numeric;
    v_amount_base   numeric;
    v_doc_ccy      text;
    v_doc_fx       numeric;
    v_alloc_base   numeric;
    v_base_total   numeric := 0;
    v_bank_base    numeric;
    v_unalloc_ccy  numeric;
    v_unalloc_base numeric;
    v_po_pay_base  numeric;
    v_realised     numeric;
    v_po_base      numeric := 0;
    v_bank         text;
    v_payment_id   uuid := gen_random_uuid();
    v_code         text;
    v_alloc        jsonb;
    v_sale_id      uuid;
    v_batch_id     uuid;
    v_expense_id   uuid;
    v_po_id        uuid;
    v_invoice_id   uuid;   -- SO-3a:订单流发票(第六种核销去处)
    v_freight_id   uuid;   -- PAY-FRT:运费单(第七个字段、第六种【付款侧】去处)
    v_alloc_usd    numeric;
    v_doc_rate     numeric;   -- 单据币种在【结算日】的牌价(折算用,不是单据入账汇率)
    v_alloc_pay    numeric;   -- 本条核销消耗掉多少【付款币种】
    v_alloc_pay_total numeric := 0;  -- Σ 消耗的付款币种额(与 p_amount 同币种比较)
    -- 控制科目要按【单据币种】逐币种发行:一笔付款可以同时结掉 USD 单和 SGD 单,
    -- 那就是两条解除行,各自的原币与各自的入账汇率。键 = 单据币种。
    v_ctrl         jsonb := '{}'::jsonb;   -- 结算类(1100 / 2000)
    v_pre          jsonb := '{}'::jsonb;   -- 预付类(1300)
    v_ccy_key      text;
    v_grp          record;
    v_doc          record;
    v_doc_value    numeric;
    v_settled      numeric;
    v_open         numeric;
    v_alloc_total  numeric := 0;
    v_je           jsonb;
    -- 拆账与两遍处理用
    v_key          text;
    v_running      jsonb := '{}'::jsonb;   -- 目标 id → 本笔内已累计核销额
    v_prior        numeric;
    v_valid        jsonb := '[]'::jsonb;   -- ①校验通过的核销行,②之后据此落库
    v_po_usd       numeric := 0;           -- 本笔中指向 PO 的预付合计(USD)
    v_ap_usd       numeric;
    v_po_ccy       numeric;
    v_ap_ccy       numeric;
    v_cap          numeric;
    v_delta        numeric;
    v_found        boolean;
    v_lines        jsonb;
    -- ── WHT-1:代扣 ──────────────────────────────────────────────────────
    -- ★【这是本函数唯一一处"贷方 ≠ 付出去的钱"的地方,而那正是代扣的定义】★
    --   供应商的债按【全额】解除(借 2000 不变),银行只走【净额】,
    --   差额贷 2150 —— 一笔对 IRAS 的负债。三个数,一条分录。
    v_wht_rate       numeric;          -- 本条核销所属债务冻下来的税率(每轮重置)
    v_wht_ccy        numeric;          -- 本条要扣多少,单据币种
    v_wht_pay        numeric;          -- 同上,折成付款币种(现金算术用)
    v_wht_pay_total  numeric := 0;     -- Σ,付款币种
    v_wht_base_total numeric := 0;     -- Σ,本位币 —— 要汇给 IRAS 的那个数
    v_payee_residence text;            -- 出款对手方申报的税务居民身份
    v_has_wht_obligation boolean;      -- 这个对手方名下有没有【要代扣的】在册债务
BEGIN
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    PERFORM require_permission('module.finance.edit');
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    v_date := p_payment_date;
    -- 1. 基础校验
    IF p_direction IS NULL OR p_direction NOT IN ('in','out') THEN
        RAISE EXCEPTION 'DIRECTION_INVALID|%', COALESCE(p_direction, '?');
    END IF;

    -- PAYEE-1a:往来对象【是哪一种】不再由 direction 推断,而是说出来的。
    -- 不填时退回本刀之前的默认('in'→客户,'out'→供应商),于是既有调用方一字不改。
    -- 【为什么不靠"在供应商里找不到就去员工里找"】那是一次静默回退:
    -- 打错一个 uuid 会从"找不到"变成"在另一张表里也找不到",错误信息指向错的地方;
    -- 而一个真的两边都存在的 id(理论上可能)会挑中谁,没有人说得清。
    v_kind := COALESCE(NULLIF(btrim(p_counterparty_kind), ''),
                       CASE WHEN p_direction = 'in' THEN 'customer' ELSE 'supplier' END);

    IF p_direction = 'in' AND v_kind <> 'customer' THEN
        RAISE EXCEPTION 'COUNTERPARTY_KIND_INVALID|%|%', p_direction, v_kind;
    END IF;
    IF p_direction = 'out' AND v_kind NOT IN ('supplier', 'employee') THEN
        RAISE EXCEPTION 'COUNTERPARTY_KIND_INVALID|%|%', p_direction, v_kind;
    END IF;

    IF v_kind = 'customer' THEN
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM customers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    ELSIF v_kind = 'supplier' THEN
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM suppliers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
        -- WHT-1:出款对手方申报的税务居民身份。**只用来决定要不要【拦】** ——
        -- 实际扣多少一律读债务上冻下来的税率,不读这一列。一个已经记下的裁定
        -- 不能因为供应商今天改了身份就变一个数(见 expenses.wht_payee_residence)。
        SELECT tax_residence INTO v_payee_residence
        FROM suppliers WHERE id = p_counterparty_id;
    ELSE
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM employees WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0 三分支:
    --   本位币                     → 1,无换算;
    --   外币、且走该币种的外币户   → 没有发生兑换,按【付款日】牌价估值:
    --                                收款 tt_buy / 付款 tt_sell,当日无牌价即拒;
    --   外币、但走的不是该币种的户 → 银行【实际做了兑换】,必须递入按银行水单
    --                                实际金额折出的汇率(C4:实际兑换用实际数,
    --                                永远不用牌价);此时 p_fx_rate 必填。
    IF p_currency = v_base THEN
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
        END IF;
        v_fx := 1;
    ELSIF bank_native_currency(COALESCE(p_bank_account,
              bank_account_for_currency(p_currency))) = p_currency THEN
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
        END IF;
        v_fx := fx_rate_for(p_currency, v_date,
                            CASE WHEN p_direction = 'in' THEN 'tt_buy' ELSE 'tt_sell' END);
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    -- 银行科目:显式给了必须合法;不给按币种默认 —— 映射只有一份
    -- (bank_account_for_currency,bank_native_currency 的逆;同 lib/currencyMap.ts)
    IF p_bank_account IS NOT NULL THEN
        IF p_bank_account NOT IN ('1000','1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
        END IF;
        v_bank := p_bank_account;
    ELSE
        v_bank := bank_account_for_currency(p_currency);
    END IF;

    -- 2. USD 金额
    v_amount_base := round(p_amount * v_fx, 2);

    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN
        RAISE EXCEPTION 'ALLOC_INVALID|not_an_array';
    END IF;

    -- ========================================================================
    -- ① 核销行:逐条校验,不落库。顺序:存在 → 归属 → 计价 → 敞口。
    --    'in' 只认 sales_record_id / invoice_id;'out' 认 inbound_batch_id /
    --    expense_id / purchase_order_id(预付)/ freight_document_id(运费,PAY-FRT)。
    -- ========================================================================
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_sale_id    := (v_alloc->>'sales_record_id')::uuid;
        v_batch_id   := (v_alloc->>'inbound_batch_id')::uuid;
        v_expense_id := (v_alloc->>'expense_id')::uuid;
        v_po_id      := (v_alloc->>'purchase_order_id')::uuid;
        v_invoice_id := (v_alloc->>'invoice_id')::uuid;
        v_freight_id := (v_alloc->>'freight_document_id')::uuid;
        v_alloc_usd  := (v_alloc->>'amount_doc')::numeric;  -- FIN-2:单据币种金额
        -- 【每一轮重置】v_doc 是一个跨臂复用的 record,各臂 SELECT 出来的形状
        -- 并不相同 —— 所以代扣税率不能挂在 v_doc 上读,必须由本变量逐轮携带。
        -- 不重置的话,上一条要代扣的核销会把税率漏给下一条不该代扣的核销,
        -- 而那是一个算得出数、不报错的错误。
        v_wht_rate := NULL;

        IF v_alloc_usd IS NULL OR v_alloc_usd <= 0
           OR num_nonnulls(v_sale_id, v_batch_id, v_expense_id, v_po_id, v_invoice_id,
                           v_freight_id) <> 1 THEN
            RAISE EXCEPTION 'ALLOC_INVALID|%', v_alloc::text;
        END IF;

        IF p_direction = 'in' THEN
            IF v_batch_id IS NOT NULL OR v_expense_id IS NOT NULL OR v_po_id IS NOT NULL
               OR v_freight_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            IF v_invoice_id IS NOT NULL THEN
                -- ════════════════════════════════════════════════════════════
                -- SO-3a:订单流发票 —— 它自己就是应收单据(开票即 借1100/贷2500)。
                -- doc_value = Σ 明细行 amount_ccy(生成列,与 order_invoice_open_all
                -- 同口径);doc_fx = 发票【存下来的】入账汇率(从订单抄来的那一个)
                -- —— 结算按它解除,已实现汇兑(7100)也从它算起。开屏现查一个
                -- "今天的"汇率,会让同一张发票每天欠不一样的钱。
                -- 只认 kind='order' 且在册:sale 头的应收在 sales_records 上,
                -- 拿它的发票来核销就是同一笔债的第二个入口(ALLOC_INVALID)。
                -- ════════════════════════════════════════════════════════════
                SELECT i.id, i.code AS doc_code, i.customer_id AS party_id,
                       (SELECT COALESCE(sum(il.amount_ccy), 0) FROM invoice_lines il
                         WHERE il.invoice_id = i.id) AS doc_value,
                       i.currency AS doc_ccy, i.fx_rate AS doc_fx
                INTO v_doc
                FROM invoices i
                WHERE i.id = v_invoice_id AND i.kind = 'order' AND i.status = 'issued';
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'ALLOC_INVALID|%', v_invoice_id;
                END IF;
                IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                    RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
                END IF;
                v_doc_value := v_doc.doc_value;
                v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
                v_key := v_invoice_id::text;

                SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.invoice_id = v_invoice_id;
            ELSE
                SELECT sr.id, ob.code AS doc_code, sr.customer_id AS party_id,
                       round(sr.quantity * sr.unit_price, 2) AS doc_value,
                       sr.currency AS doc_ccy, sr.fx_rate AS doc_fx
                INTO v_doc
                FROM sales_records sr
                JOIN output_batches ob ON ob.id = sr.output_batch_id
                WHERE sr.id = v_sale_id;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'ALLOC_INVALID|%', v_sale_id;
                END IF;
                IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                    RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
                END IF;
                v_doc_value := v_doc.doc_value;
                v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
                v_key := v_sale_id::text;

                SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.sales_record_id = v_sale_id;
            END IF;

        ELSIF v_po_id IS NOT NULL THEN
            -- 预付款:PO 上【没有敞口上限】—— 定金不是在还债,那一刻还没有债。
            -- 唯一的栏杆是"累计预付不得超过估算总额 × 1.5",防手滑多打一个零。
            SELECT po.id, po.code AS doc_code, po.supplier_id AS party_id,
                   po.estimated_total_ccy, po.status AS po_status,
                   po.currency AS doc_ccy, po.fx_rate AS doc_fx,
                   po.approval_status AS po_approval
            INTO v_doc
            FROM purchase_orders po
            WHERE po.id = v_po_id AND po.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_po_id;
            END IF;
            IF v_doc.po_status = 'cancelled' THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_doc.doc_code;
            END IF;
            -- APR-2:未获批的采购单不能收预付款
            IF v_doc.po_approval <> 'approved' THEN
                RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_doc.doc_code, v_doc.po_approval;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            -- ★【WHT-1(A3):预付不在本刀范围内 —— 按名拒,不静默略过】★
            --   它在等的判断更硬:付给非居民顾问的一笔【定金】,本身就是一次
            --   代扣事件 —— 发生在任何发票存在【之前】,而这一刀的债务载体
            --   (expenses)那时还不存在。也就是说这不是"忘了接一根线",
            --   是本刀的裁定(代扣是债务的属性)在这条路上【还没有主语】。
            IF v_payee_residence = 'non_resident' THEN
                RAISE EXCEPTION 'WHT_PREPAYMENT_NOT_SUPPORTED|%', v_doc.doc_code
                  USING HINT = '付给非居民的定金本身就是一次代扣事件,而它发生在任何费用单之前 —— 本刀把代扣挂在债务上,预付那条路还没有债务可挂';
            END IF;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_key := v_po_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.purchase_order_id = v_po_id;

            -- 1.5 倍是【刻意留出的余量】:估算按谈价时的行情算,实际化验和金属价格
            -- 波动都会把真实金额顶高,预付超过估算是正常的;超过一半就不正常了。
            -- 【这条上限【不需要】折算 —— 两边本来就同币种,别再"顺手"加一次】
            -- v_alloc_usd 取自 amount_doc,按定义就是【单据币种】的金额;
            -- v_cap = estimated_total_ccy × 1.5,而 estimated_total_ccy 存的也是
            -- 【单据币种】(create_purchase_order 直接累加行金额,全程不乘汇率;
            -- 名字里的 _usd 是 FIN-1a 留下的旧名,与内容不符,见 docs/known-issues.md)。
            -- 两边同币种 ⇒ 付款是什么币种与这条上限【无关】,fixture 已断言:
            -- 同一张 PO、同一个 amount_doc,SGD 付款与 USD 付款结论完全一致。
            --
            -- 【FIN-16 曾经在这里写过一段相反的注释】,说这一支"需要单独折算"。
            -- 那是错的:代码从未折算,也不该折算,而那段注释举的例子(SGD 8,000 对
            -- USD 6,000 估算)两种算法都放行,根本区分不出有没有折算。
            -- 真正需要折算的是【付款额】那条守卫 ALLOC_EXCEEDS_PAYMENT ——
            -- 见下方 Σ 比较处;跨币种预付会不会超付,由它把关,不由这条上限把关。
            v_cap := round(v_doc.estimated_total_ccy * 1.5, 2);
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            IF round(v_settled + v_prior + v_alloc_usd, 2) > v_cap THEN
                RAISE EXCEPTION 'PREPAY_EXCEEDS_ESTIMATE|%|%|%',
                    v_doc.doc_code, round(v_settled + v_prior + v_alloc_usd, 2), v_cap;
            END IF;

            v_po_usd := round(v_po_usd + v_alloc_usd, 2);  -- FIN-2 起为单据币种累计
            v_doc_value := NULL;  -- 无敞口上限,跳过下面的 ALLOC_EXCEEDS

        ELSIF v_batch_id IS NOT NULL THEN
            IF v_sale_id IS NOT NULL OR v_invoice_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            SELECT ib.id, ib.code AS doc_code, ib.supplier_id AS party_id,
                   ib.unit_price, ib.quantity
            INTO v_doc
            FROM inbound_batches ib
            WHERE ib.id = v_batch_id AND ib.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_batch_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            IF v_doc.unit_price IS NULL THEN
                RAISE EXCEPTION 'ALLOC_UNPRICED|%', v_doc.doc_code;
            END IF;
            -- 应付额永远对着"当前"批次价值(改价即改欠款)
            v_doc_value := round(v_doc.quantity * v_doc.unit_price, 2);
            v_doc_ccy := v_base; v_doc_fx := 1;  -- FIN-0 起批次价值即本位币
            v_key := v_batch_id::text;

            -- 已结 = 收付款核销 + 预付冲抵(B6 起,预付冲抵也在还这张单的应付)
            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.inbound_batch_id = v_batch_id;
            v_settled := v_settled + COALESCE(
                (SELECT SUM(ppa.amount_base) FROM prepayment_applications ppa
                  WHERE ppa.inbound_batch_id = v_batch_id), 0);

        ELSIF v_freight_id IS NOT NULL THEN
            IF v_sale_id IS NOT NULL OR v_invoice_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            -- ════════════════════════════════════════════════════════════════
            -- PAY-FRT:未付运费单 —— 对手方是【货代】。
            -- 【这一臂逐字照着开支臂写,不是巧合,是判据】两者是同一种单据:
            -- 一张自带币种与入账汇率、贷 2000、挂在一个往来对象名下的应付。
            -- 于是敞口、跨币种结算、已实现汇兑三条全部落在下面【共用】的那段里,
            -- 本臂一行新的 FX 算术都没有 —— 新算术就是第二份算术。
            -- 【筛选条件与 ap_open_items 的运费支逐字一致】unpaid + posted +
            -- 未软删。少一条,画面上能选到的单据与这里能核销的单据就会分家,
            -- 而那正是本刀在关的那种缝。
            -- 【不存在 / 已付 / 已冲销 / 已软删 一律 ALLOC_INVALID】同开支臂:
            -- 四种情况在【调用方能做的事】上没有区别 —— 都是"这张单不能被核销"。
            -- ════════════════════════════════════════════════════════════════
            SELECT fd.id, fd.code AS doc_code, fd.supplier_id AS party_id,
                   fd.amount_ccy AS doc_value, fd.currency AS doc_ccy, fd.fx_rate AS doc_fx
            INTO v_doc
            FROM freight_documents fd
            WHERE fd.id = v_freight_id AND fd.payment_status = 'unpaid'
              AND fd.status = 'posted' AND fd.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_freight_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            -- ★【WHT-1(A3):运费不在本刀范围内 —— 按名拒,不静默略过】★
            --   它在等一个【没有人做过】的判断:付给非居民的运费,收款人如果是
            --   船公司/航空公司,是法定豁免的;如果是提供代理服务的货代,未必。
            --   两种情形在 freight_documents 上长得一模一样,而系统分不出来。
            --   静默放过 = 一笔本该代扣的款一分钱都没扣,且看起来完全正常。
            IF v_payee_residence = 'non_resident' THEN
                RAISE EXCEPTION 'WHT_FREIGHT_NOT_SUPPORTED|%', v_doc.doc_code
                  USING HINT = '付给非居民的运费是否代扣,取决于收款人是船公司/航空公司(豁免)还是提供代理服务的货代 —— 这个判断还没有人做过,本刀不猜';
            END IF;
            v_doc_value := v_doc.doc_value;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_key := v_freight_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.freight_document_id = v_freight_id;

        ELSE
            IF v_sale_id IS NOT NULL OR v_invoice_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            -- 挂账开支:必须是 unpaid + posted(不存在/已付/已冲销 → ALLOC_INVALID)
            -- PAYEE-1a:往来对象二选一,所以 party_id 取"那一个"。
            -- CHECK 保证 num_nonnulls(supplier_id, employee_id) = 1,于是 COALESCE
            -- 不会把两个混起来 —— 它挑的是唯一非空的那个。
            SELECT e.id, e.code AS doc_code, COALESCE(e.supplier_id, e.employee_id) AS party_id,
                   e.amount_ccy AS doc_value, e.currency AS doc_ccy, e.fx_rate AS doc_fx,
                   -- WHT-1:代扣率来自【债务自己冻下来的那一个】,不在这里重新解析。
                   -- 重新解析 = 第二份实现,而它会在法定税率某天变动之后,
                   -- 让一张旧债务按新税率被代扣 —— 算得出数,没有任何报错。
                   e.wht_rate_pct AS wht_rate_pct
            INTO v_doc
            FROM expenses e
            WHERE e.id = v_expense_id AND e.payment_status = 'unpaid' AND e.status = 'posted';
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_expense_id;
            END IF;
            v_wht_rate := v_doc.wht_rate_pct;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_doc_value := v_doc.doc_value;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_key := v_expense_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.expense_id = v_expense_id;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【FIN-16】核销额是【单据的】金额,以单据币种计 —— 这一条来自 FIN-2,没变,
        -- 也正是它让单据恰好归零。变的是:付款【不必】是同一币种。
        -- 欠 USD 6,000 的客户拿 SGD 付清,这张单就是清了 —— 从前拒绝它不是安全护栏,
        -- 是缺了一个功能(旧 ALLOC_CURRENCY_MISMATCH 已删)。
        -- 本条核销消耗多少付款币种,由【结算日】两个币种的牌价折出来:
        --     消耗 = 单据额 × rate(单据币种) / rate(付款币种)
        -- 同币种时两率相同、比值为 1 —— 老路径逐字节不变,不需要特判。
        -- ════════════════════════════════════════════════════════════════════
        IF v_doc_ccy = p_currency THEN
            v_alloc_pay := v_alloc_usd;
        ELSE
            v_doc_rate := fx_rate_for(v_doc_ccy, v_date,
                            CASE WHEN p_direction = 'in' THEN 'tt_buy' ELSE 'tt_sell' END);
            v_alloc_pay := round(v_alloc_usd * v_doc_rate / v_fx, 2);
        END IF;
        v_alloc_pay_total := v_alloc_pay_total + v_alloc_pay;
        v_alloc_base := round(v_alloc_usd * v_doc_fx, 2);
        v_base_total := v_base_total + v_alloc_base;
        IF v_po_id IS NOT NULL THEN v_po_base := v_po_base + v_alloc_base; END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【WHT-1:代扣多少 —— 按【实际付掉的这一部分】算,不是按债务总额】
        -- 法定义务是"就你付出去的那部分代扣",所以部分结清只扣部分。
        -- 【为什么不按比例摊那张单冻下来的 wht_amount_ccy】按比例摊会在
        -- 多次部分付款之间累积取整误差,最后一次要靠"补齐余额"收口 ——
        -- 而那是一段谁都不敢改的算术。直接乘税率:每一次都精确,而且
        -- 全额付清时 Σ 恰好等于那张单冻下来的预期值(fixture 142 D 臂钉它)。
        IF v_wht_rate IS NOT NULL AND v_wht_rate > 0 THEN
            v_wht_ccy := round(v_alloc_usd * v_wht_rate / 100.0, 2);
            -- 折成付款币种走的是【与这条核销完全相同的那一步】,而不是另写一遍:
            -- 同币种取自身,跨币种用上面刚算出来的 v_doc_rate。
            IF v_doc_ccy = p_currency THEN
                v_wht_pay := v_wht_ccy;
            ELSE
                v_wht_pay := round(v_wht_ccy * v_doc_rate / v_fx, 2);
            END IF;
            v_wht_pay_total := v_wht_pay_total + v_wht_pay;
        ELSE
            v_wht_ccy := 0; v_wht_pay := 0;
        END IF;

        -- 敞口校验(预付除外:v_doc_value 为 NULL)。v_running 让同一目标在同一笔里
        -- 出现两次时,后一条能看见前一条 —— 原实现靠"边插边查"拿到的就是这个语义。
        IF v_doc_value IS NOT NULL THEN
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            v_open := round(v_doc_value - v_settled - v_prior, 2);
            IF v_alloc_usd > v_open THEN
                RAISE EXCEPTION 'ALLOC_EXCEEDS|%|%|%', v_doc.doc_code, v_alloc_usd, v_open;
            END IF;
        END IF;

        -- 按单据币种归集,供下面逐币种发行控制科目行
        v_ccy_key := v_doc_ccy;
        IF v_po_id IS NOT NULL THEN
            -- 预付是【非货币性】的,按付款日口径入账 —— 基准额取"消耗掉的付款额 ×
            -- 付款汇率",不是单据入账汇率(同币种时两者相等,老行为不变)。
            v_pre := v_pre || jsonb_build_object(v_ccy_key, jsonb_build_object(
                'ccy',  COALESCE((v_pre->v_ccy_key->>'ccy')::numeric, 0) + v_alloc_usd,
                'base', COALESCE((v_pre->v_ccy_key->>'base')::numeric, 0)
                        + round(v_alloc_pay * v_fx, 2)));
        ELSE
            v_ctrl := v_ctrl || jsonb_build_object(v_ccy_key, jsonb_build_object(
                'ccy',  COALESCE((v_ctrl->v_ccy_key->>'ccy')::numeric, 0) + v_alloc_usd,
                'base', COALESCE((v_ctrl->v_ccy_key->>'base')::numeric, 0) + v_alloc_base));
        END IF;

        v_running := v_running || jsonb_build_object(
            v_key, COALESCE((v_running->>v_key)::numeric, 0) + v_alloc_usd);
        v_valid := v_valid || jsonb_build_array(jsonb_build_object(
            'sales_record_id', v_sale_id, 'inbound_batch_id', v_batch_id,
            'expense_id', v_expense_id, 'purchase_order_id', v_po_id,
            'invoice_id', v_invoice_id, 'freight_document_id', v_freight_id,
            'amount_ccy', v_alloc_usd, 'amount_base', v_alloc_base,
            -- FIN-18:【消耗掉多少付款额】要落库。它是本函数唯一算得出、别处
            -- 再也算不回来的数 —— 见文件头。
            'amount_pay', v_alloc_pay,
            -- WHT-1:其中【没有付出去】的那一部分。allocated_pay 仍然是全额 ——
            -- 供应商的债确实按全额解除了,改它的含义会让 FIN-18 那段注释说谎。
            'withheld_pay', v_wht_pay,
            'withheld_base', round(v_wht_pay * v_fx, 2)));
        v_alloc_total := v_alloc_total + v_alloc_usd;
    END LOOP;

    -- Σ 核销不得超过款额(欠核销 = 挂账余额,允许)
    -- 【与页面同一个毛病的服务端孪生】v_alloc_total 是【单据币种】的合计,
    -- p_amount 是【付款币种】。同币种时看不出来;一旦不同,就是两种货币相减。
    -- 比较必须在付款币种空间做 —— 这正是两切次前在 /finance/payments 上修掉的
    -- 那个 bug,只是长在服务端。
    -- ════════════════════════════════════════════════════════════════════════
    -- ★【WHT-1:这一行【就是】代扣的结构位置,而它此前是不可能的】★
    --   本函数原来的不变量是 Σ核销 ≤ 付款额 —— 也就是【核销永远不能超过现金】。
    --   代扣要的恰恰是超过:结掉 10,000 的债,只付出去 8,500。
    --   于是比较的左边减去代扣额:**真正要与现金比的,是"要付出去的那部分"**。
    --   少了这一句,每一笔带代扣的付款都会撞上 ALLOC_EXCEEDS_PAYMENT,
    --   而错误信息会指向一个完全无辜的地方(看起来像超付)。
    IF round(v_alloc_pay_total - v_wht_pay_total, 2) > p_amount THEN
        RAISE EXCEPTION 'ALLOC_EXCEEDS_PAYMENT|%|%',
            round(v_alloc_pay_total - v_wht_pay_total, 2), p_amount;
    END IF;
    -- 【FIN-3 修订的 C2】已实现汇兑在【结算时点】认列:
    --   控制科目按【单据的】汇率解除(不变);银行按【结算日】口径(牌价/实际);
    --   差额进 7100(已实现)。只要单据汇率和当日汇率,两个数,不追每一块钱的均价。
    -- 未核销部分与预付(非货币,按付款日历史汇率入账)都按当日口径,不产生已实现差异。
    v_bank_base    := round(p_amount * v_fx, 2);
    v_amount_base  := v_bank_base;
    -- 未核销 = 款额 − 【已消耗的付款币种额】。原先减的是 v_alloc_total(单据币种合计)
    -- —— 同币种时相等,不同币种时就是两种货币相减,与 ALLOC_EXCEEDS_PAYMENT 同一个错。
    -- WHT-1:挂账 = 款额 − 【实际付掉的】那部分,而代扣的那部分从来没有付出去。
    -- 不减它,每一笔带代扣的付款都会凭空多出一笔等于代扣额的"挂账余额" ——
    -- 一笔并不存在的、对供应商的预付。
    v_unalloc_ccy  := round(p_amount - (v_alloc_pay_total - v_wht_pay_total), 2);
    v_unalloc_base := round(v_unalloc_ccy * v_fx, 2);
    -- 要汇给 IRAS 的那个数。**按付款当日汇率折本位币** —— 代扣是今天新产生的
    -- 一笔负债,不是在解除一笔旧的(与预付 1300 同一条口径)。IRAS 只收新元。
    v_wht_base_total := round(v_wht_pay_total * v_fx, 2);

    -- ════════════════════════════════════════════════════════════════════════
    -- ★【WHT-1(A4):挂账付款给非居民 —— 【窄】的那一版拒绝】★
    --   一笔挂不上任何单据的出款,系统说不出它是什么性质,于是解析不出税率。
    --   GST 那一侧对【挂账收款】的处置是无条件按名拒
    --   (GST_UNALLOCATED_RECEIPT_UNSUPPORTED),而这里【故意不照抄】——
    --   理由必须写在这里,因为一次没有解释的、与兄弟规矩不同的做法,
    --   在下一个人读起来就是一处疏漏:
    --
    --   **那一条广,是因为在一笔挂账收款上,关于那项供应【什么都不可知】。
    --     这里不同:一个只卖过货的非居民,他的款一分钱都不该代扣 ——
    --     拦下它,是为了一个对他并不成立的理由而拦下一件正当的事。**
    --   而一条会在不适用的情形上开火的拒绝,会教会人绕开它 ——
    --   这个仓库为"学会忽略警报"付过账(hr_alerts.system_start_not_set)。
    --
    --   所以谓词收窄成:非居民 **且** 名下确实有过要代扣的债务。
    --   【残留的缺口,照直写】一个非居民,名下从来没有过要代扣的费用单,
    --   而这笔挂账付款正是给他的一项服务的预付 —— 它会通过。按名记在
    --   docs/known-issues.md,那是选窄版买来的代价,不是没想到。
    IF p_direction = 'out' AND v_unalloc_ccy > 0 AND v_payee_residence = 'non_resident' THEN
        SELECT EXISTS (
            SELECT 1 FROM expenses e
             WHERE e.supplier_id = p_counterparty_id
               AND e.status = 'posted'
               AND e.wht_nature IS NOT NULL
               AND e.wht_nature <> 'none'
        ) INTO v_has_wht_obligation;
        IF v_has_wht_obligation THEN
            RAISE EXCEPTION 'WHT_UNALLOCATED_PAYMENT_UNSUPPORTED|%|%', v_unalloc_ccy, p_currency
              USING HINT = '这个非居民收款人名下有要代扣的债务,而一笔挂账的款说不出它是什么性质、扣多少 —— 先记费用单,再核销到它上面';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【GST-2:"孰早"那条规矩的【另一半】,按名拦住而不是沉默地放过】
    -- 新加坡的供应时点是【开票与收款孰早】。GST-2 实现的是开票那一半;
    -- 收款那一半 —— 一笔【先于任何发票】收到的客户款 —— 同样触发供应,
    -- 而这套系统实现不了它:收款那一刻没有任何东西说得出这笔钱对应哪一项供应,
    -- 于是税码、税率、进哪一格三者都无从解析。
    -- **一条有两半的规矩,不许只做一半就当做完了。** 处置因此是按名拒绝:
    -- 已注册时,一笔挂不上任何单据的客户收款走不下去 —— 先开票,再收款核销。
    -- 【为什么不是"照收,记进 known-issues 就算了"】那样账上会留下一笔
    -- 【已经触发了供应却没有报税】的钱,而它看起来与一笔正常的挂账收款一模一样。
    -- 返回条件写在 docs/known-issues.md。
    IF p_direction = 'in' AND v_unalloc_ccy > 0 AND gst_registered() THEN
        RAISE EXCEPTION 'GST_UNALLOCATED_RECEIPT_UNSUPPORTED|%|%', v_unalloc_ccy, p_currency
          USING HINT = '已注册 GST 时,客户款必须核销到单据上:先开票,再收款';
    END IF;
    -- 预付部分占用的付款额(付款币种)→ 基准。原式 v_po_usd × v_fx 把单据币种的
    -- 数乘了付款汇率,跨币种时不成立;改为按各币种累加出来的基准额直接求和。
    SELECT COALESCE(SUM((value->>'base')::numeric), 0) INTO v_po_pay_base
    FROM jsonb_each(v_pre);
    -- 已实现 = 单据口径解除额 − 当日口径(同币种两率同为 1 ⇒ 恒为 0,不出现 FX 行)
    v_realised := round((v_base_total - v_po_base) - round((v_alloc_total - v_po_usd) * v_fx, 2), 2);

    -- ========================================================================
    -- ② 分录。'out' 且本笔含 PO 预付时【拆两条借方】:
    --      借 1300 预付款项  = 指向 PO 的部分
    --      借 2000 应付账款  = 其余(含未核销部分 —— 与改动前对全额借 2000 一致)
    --      贷 银行          = 全额
    --    金额:核销额是 USD,分录行按原币记,故 po_ccy = round(po_usd / fx, 2),
    --    ap_ccy = p_amount − po_ccy(【相减而非各自取整】,保证两条借方的原币恰好
    --    合计等于贷方)。USD 侧由 post_journal_entry 用 round(ccy × fx, 2) 反算,
    --    非本位币下双重取整可能差 1 分,故下面在 ±0.02 内挑一个能让 USD 恰好配平的
    --    拆分点(USD 付款 fx=1,偏移恒为 0)。
    -- ========================================================================
    v_code := fin_next_payment_code(CASE WHEN p_direction = 'in' THEN 'RCPT' ELSE 'PMT' END, v_date);

    -- 行 fx = 目标基准额 ÷ 原币额(除后反乘取整恰好还原);0 金额行一律不发。
    v_lines := '[]'::jsonb;
    IF p_direction = 'in' THEN
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'debit',
            'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_bank_base / p_amount);
        -- 【逐单据币种】解除应收:金额是单据的原币,汇率是单据的入账汇率。
        -- 原先这里写死 p_currency —— 同币种时看不出来,两种币种时标签就是错的。
        FOR v_grp IN SELECT key AS ccy, (value->>'ccy')::numeric AS ccy_amt,
                            (value->>'base')::numeric AS base_amt
                     FROM jsonb_each(v_ctrl) ORDER BY key
        LOOP
            IF v_grp.ccy_amt > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '1100', 'side', 'credit',
                    'currency', v_grp.ccy, 'amount_ccy', v_grp.ccy_amt,
                    'fx_rate', v_grp.base_amt / v_grp.ccy_amt,
                    'line_memo', 'settled at document rate');
            END IF;
        END LOOP;
        IF v_unalloc_ccy > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '1100', 'side', 'credit',
                'currency', p_currency, 'amount_ccy', v_unalloc_ccy, 'fx_rate', v_unalloc_base / v_unalloc_ccy);
        END IF;
        -- 已实现差额:贷方合计 − 银行借方。>0 = 损(补借 7100),<0 = 益(补贷 7100)
        v_realised := round(COALESCE(v_base_total, 0) + v_unalloc_base - v_bank_base, 2);
        IF v_realised > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
                'currency', base_currency_code(), 'amount_ccy', v_realised);
        ELSIF v_realised < 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', -v_realised);
        END IF;
    ELSE
        FOR v_grp IN SELECT key AS ccy, (value->>'ccy')::numeric AS ccy_amt,
                            (value->>'base')::numeric AS base_amt
                     FROM jsonb_each(v_ctrl) ORDER BY key
        LOOP
            IF v_grp.ccy_amt > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '2000', 'side', 'debit',
                    'currency', v_grp.ccy, 'amount_ccy', v_grp.ccy_amt,
                    'fx_rate', v_grp.base_amt / v_grp.ccy_amt,
                    'line_memo', 'settled at document rate');
            END IF;
        END LOOP;
        IF v_unalloc_ccy > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '2000', 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_unalloc_ccy, 'fx_rate', v_unalloc_base / v_unalloc_ccy);
        END IF;
        FOR v_grp IN SELECT key AS ccy, (value->>'ccy')::numeric AS ccy_amt,
                            (value->>'base')::numeric AS base_amt
                     FROM jsonb_each(v_pre) ORDER BY key
        LOOP
            IF v_grp.ccy_amt > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '1300', 'side', 'debit',
                    'currency', v_grp.ccy, 'amount_ccy', v_grp.ccy_amt,
                    'fx_rate', v_grp.base_amt / v_grp.ccy_amt,
                    'line_memo', 'Prepayment');
            END IF;
        END LOOP;
        -- ════════════════════════════════════════════════════════════════════
        -- ★【WHT-1:代扣的那一笔 —— 债全额解除,钱只走净额】★
        --   借方(2000)已经是【全额】,银行贷方是【净额】(调用方递进来的
        --   p_amount 就是实际离开银行的钱),差额在这里贷 2150。
        --   **这就是 3.2 说的"代扣不是折扣"落成分录的样子**:供应商那张单
        --   闭合到零,而银行只动了净额,中间那一笔成为对 IRAS 的负债。
        --   【本位币记账,不带原币敞口】IRAS 只收新元,代扣额在付款那一刻
        --   就固定成一个新元数字 —— 它此后不再随汇率变动,所以这条腿走
        --   base_currency_code(),与 7100 那两条同一种写法。
        IF v_wht_base_total > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '2150', 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', v_wht_base_total,
                'line_memo', 'Withholding tax on ' || v_code);
        END IF;
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'credit',
            'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_bank_base / p_amount);
        -- 借方合计 − 银行贷方:>0 说明按旧率解除得多 → 贷 7100(益);<0 → 借 7100(损)
        -- 【减去代扣额】它是一条【新增的贷方】,不减就会被整个算进已实现汇兑,
        -- 把一笔代扣伪装成一笔汇兑损失 —— 而分录仍然是平的,不会有任何报错。
        v_realised := round((v_base_total - v_po_base) + v_unalloc_base + v_po_pay_base
                            - v_bank_base - v_wht_base_total, 2);
        IF v_realised > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', v_realised);
        ELSIF v_realised < 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
                'currency', base_currency_code(), 'amount_ccy', -v_realised);
        END IF;
    END IF;

    v_je := post_journal_entry(
        v_date,
        CASE WHEN p_direction = 'in' THEN 'Receipt ' ELSE 'Payment ' END || v_code,
        'payment', v_payment_id, v_lines);

    -- ③ 插入收付款单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          employee_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_payment_id, v_code, p_direction,
            v_kind,
            CASE WHEN v_kind = 'customer' THEN p_counterparty_id END,
            CASE WHEN v_kind = 'supplier' THEN p_counterparty_id END,
            CASE WHEN v_kind = 'employee' THEN p_counterparty_id END,
            p_amount, p_currency, v_fx, v_amount_base, v_bank,
            v_date, p_notes, (v_je->>'entry_id')::uuid, v_user);

    -- ④ 核销行落库(①已全部校验过,这里只写)
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(v_valid)
    LOOP
        INSERT INTO payment_allocations (payment_id, sales_record_id, inbound_batch_id,
                                         expense_id, purchase_order_id, invoice_id,
                                         freight_document_id,
                                         allocated_ccy, allocated_base, allocated_pay,
                                         withheld_pay, withheld_base)
        VALUES (v_payment_id,
                (v_alloc->>'sales_record_id')::uuid,
                (v_alloc->>'inbound_batch_id')::uuid,
                (v_alloc->>'expense_id')::uuid,
                (v_alloc->>'purchase_order_id')::uuid,
                (v_alloc->>'invoice_id')::uuid,
                (v_alloc->>'freight_document_id')::uuid,
                (v_alloc->>'amount_ccy')::numeric,
                (v_alloc->>'amount_base')::numeric,
                (v_alloc->>'amount_pay')::numeric,
                (v_alloc->>'withheld_pay')::numeric,
                (v_alloc->>'withheld_base')::numeric);
    END LOOP;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【FIN-18】返回值里原有 allocated_total = v_alloc_total 与
    -- unallocated = p_amount - v_alloc_total。函数体早已把分录与
    -- ALLOC_EXCEEDS_PAYMENT 都改到 v_alloc_pay_total(付款币种),【只有返回值
    -- 留在原地】:v_alloc_total 是各单据币种核销额的直接相加 —— 一张 USD 单
    -- 加一张 SGD 单;拿它去减付款币种的 p_amount 更是两种货币相减。
    -- 今天没有调用方读它(action 只取 payment_id),所以它不是 bug,是给下一个
    -- 调用方埋的坑。带单位的换上,没单位的撤掉。
    -- ════════════════════════════════════════════════════════════════════════
    RETURN jsonb_build_object(
        'payment_id', v_payment_id,
        'code', v_code,
        'currency', p_currency,                       -- 下面两个数的单位
        'amount_base', v_amount_base,
        'journal_code', v_je->>'code',
        'allocated_pay_total', round(v_alloc_pay_total, 2),  -- 付款币种:消耗掉的款额
        'unallocated', v_unalloc_ccy,                        -- 付款币种:挂账余额
        -- WHT-1:代扣了多少。**两个数分开报,而且各自带单位** ——
        -- withheld_pay 是现金算术里的那个数(付款币种),
        -- withheld_base 是【要汇给 IRAS 的那个数】(本位币)。
        -- 合成一个会重蹈 FIN-18 那个坑:一个没有单位的数,给下一个调用方埋雷。
        'withheld_pay_total', round(v_wht_pay_total, 2),
        'withheld_base_total', v_wht_base_total,
        -- 单据币种的核销额【按币种分开列】,不求和
        'settled_by_ccy', (SELECT COALESCE(jsonb_object_agg(key, value->'ccy'), '{}'::jsonb)
                             FROM jsonb_each(v_ctrl)),
        'prepaid_by_ccy', (SELECT COALESCE(jsonb_object_agg(key, value->'ccy'), '{}'::jsonb)
                             FROM jsonb_each(v_pre))
    );
END;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- 12 · remit_wht —— 汇给 IRAS,而这是那条告警唯一的清除方式
-- ─────────────────────────────────────────────────────────────────────────────

-- db/functions/remit_wht.sql
-- WHT-1:把一个代扣月的预提税汇给 IRAS。
--
-- ★【它与 pay_payroll_cpf 是同一个形状,而那不是巧合 —— 是同一件事】★
--   两者都是【从别人的钱里扣下来、替他交给一个法定机构】:CPF 扣自员工的薪,
--   预提税扣自非居民收款人的款。所以两者的分录逐字同形(借那笔负债 / 贷银行)、
--   都在次月到期、都不豁免期间锁,而且【告警清除的条件都是钱真的动了】。
--   两个到期日不同(CPF 次月 14 日、预提税次月 15 日),各自来自各自的法令 ——
--   **不要"顺手统一"**:一个凑整过的法定期限,是一个会让公司逾期的数字。
--
-- ★【为什么不需要"先打开一期"】★ gst_periods 要先 open_gst_period 才能申报;
--   这里没有那个动作,因为【欠多少是推导出来的】(wht_liability_by_month 从总账
--   读代扣),不需要谁先声明这个月存在。于是"没有人开这一期,于是这个月的税
--   悄悄没人管"这种失败模式,在结构上不存在。
--
-- FIN-10:日期没有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。默认成今天
-- 永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关。

CREATE OR REPLACE FUNCTION public.remit_wht(p_period_month date, p_remitted_on date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_month   date;
    v_amount  numeric;
    v_bank    text;
    v_base    text;
    v_ref     text;
    v_seq     integer;
    v_code    text;
    v_je      jsonb;
    v_id      uuid := gen_random_uuid();
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】一支不问的 definer 函数就是一条
    -- 绕过 RLS 的路。这个形状在本仓库【上线过两次、被闸抓住两次】——
    -- 写在这里是因为下一支新函数最容易漏的就是这一行。
    PERFORM require_permission('module.finance.edit');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'WHT_PERIOD_REQUIRED';
    END IF;
    v_month := date_trunc('month', p_period_month)::date;

    IF p_remitted_on IS NULL THEN
        RAISE EXCEPTION 'WHT_REMIT_DATE_REQUIRED|%', v_month;
    END IF;
    IF p_remitted_on < v_month THEN
        -- 还没发生的代扣汇不出去。
        RAISE EXCEPTION 'WHT_REMIT_DATE_BEFORE_PERIOD|%|%', p_remitted_on, v_month;
    END IF;

    -- 【参考号必填,而 gst_periods 那一条允许空 —— 两者不是同一件事】
    -- GST 那边"申报"与"缴款"是两个动作,回执可能晚到;这里是【一次缴款】,
    -- 而一笔说不出参考号的缴款,日后对着 IRAS 无从交代。
    v_ref := NULLIF(btrim(COALESCE(p_filed_reference, '')), '');
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'WHT_FILED_REFERENCE_REQUIRED|%', v_month
          USING HINT = '填 IRAS S45 申报的回执/参考号 —— 一笔交代不出出处的缴款,日后无从对账';
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 【银行必须是本位币户,而这一条【故意】比 pay_payroll_cpf 严】
    -- IRAS 只收新元。pay_payroll_cpf 允许 1010 却把两条腿都按本位币记 ——
    -- 那意味着一笔从美元户走的钱会被记成等额新元离开,而实际离开的是美元。
    -- 那一支不在本刀范围内(不顺手改别人的函数),但这一支不复制它。
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    IF bank_native_currency(v_bank) <> v_base THEN
        RAISE EXCEPTION 'WHT_REMIT_BANK_NOT_BASE|%|%', v_bank, bank_native_currency(v_bank)
          USING HINT = 'IRAS 只收本位币 —— 从外币户汇出去要先兑换,而那笔兑换是它自己的一笔交易';
    END IF;

    -- 【欠多少从那张视图读,不在这里再算一遍】视图是唯一的实现,而它对
    -- 冲销的处理(经 journal_activity_lines)是这条链上最容易写错的一段。
    -- 在这里重算 = 第二份实现,而两份会在写下来那天一致、之后悄悄分开。
    SELECT unremitted_base INTO v_amount
    FROM wht_liability_by_month WHERE period_month = v_month;

    IF COALESCE(v_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'WHT_NOTHING_TO_REMIT|%|%', v_month, COALESCE(v_amount, 0)
          USING HINT = '这个月没有未汇的代扣税 —— 也可能是已经汇过了(补汇是新的一行,不是改旧的那一行)';
    END IF;

    -- 分录走【普通过账路径】,所以期间锁照常生效 —— 与 CPF 同一条:
    -- 一笔汇款不因为它是法定义务就可以进一个已经关掉的月份。
    v_je := post_journal_entry(
        p_remitted_on,
        'Withholding tax remittance ' || to_char(v_month, 'YYYY-MM'),
        'wht_remittance', v_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2150', 'side', 'debit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'WHT for ' || to_char(v_month, 'YYYY-MM')),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'IRAS ' || v_ref)));

    -- 编号:同一个月可以有多笔(补汇),第二笔起带序号。
    -- 咨询锁串行化,与 EXP/JE/收付款的取号手法一致。
    PERFORM pg_advisory_xact_lock(hashtext('wht_remit_' || to_char(v_month, 'YYYY-MM'))::bigint);
    SELECT COUNT(*) + 1 INTO v_seq FROM wht_remittances WHERE period_month = v_month;
    v_code := 'WHT-' || to_char(v_month, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    INSERT INTO wht_remittances (id, code, period_month, remitted_on, amount_base,
                                 filed_reference, journal_entry_id, notes, created_by)
    VALUES (v_id, v_code, v_month, p_remitted_on, v_amount,
            v_ref, (v_je->>'entry_id')::uuid, p_notes, auth.uid());

    RETURN jsonb_build_object(
        'remittance_id', v_id,
        'code', v_code,
        'period_month', v_month,
        'remitted_on', p_remitted_on,
        'amount_base', v_amount,
        'currency', v_base,
        'filed_reference', v_ref,
        'journal_code', v_je->>'code');
END;
$function$;

COMMENT ON FUNCTION public.remit_wht(date, date, text, text, text) IS
'WHT-1:把一个代扣月的预提税汇给 IRAS(借 2150 / 贷银行),并留下一行只可追加的
汇款记录。**这一支是 operations_now 的 wht_due 那一支【唯一】的清除方式** ——
告警的谓词读的是 wht_liability_by_month.unremitted_base,而这个数只有在
一张真的分录把 2150 借掉之后才会下降。也就是说:**清除告警 ⇔ 钱真的动了**,
没有"知道了"按钮。与 CPF 的 cpf_paid_at 逐字同一条,而理由写在那里:
一个点一下就消失的告警,清除的是人的注意力,不是那件事。';


-- ─────────────────────────────────────────────────────────────────────────────
-- 13 · operations_now —— 第 30 支:wht_due
-- ─────────────────────────────────────────────────────────────────────────────
-- 【加一支会让 check-i18n 自动变宽】dashboard.item.* 的后缀集合是从本视图的
-- 'x'::text AS item_type 字面量现读的,所以 messages/en.ts 与 zh.ts 必须
-- 同时有 dashboard.item.wht_due —— 漏了,构建当场红。

-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行
--
-- 【为什么是一张视图而不是九个页面各查各的】仪表盘的每一块牌子背后都是"有多少件
-- 事在等"这一类问题;九个问题九处写,就是九份会各自漂移的实现。hr_alerts 已经证明
-- 过这个形状:一个 UNION,每一种等待状态一支,页面只负责画。
--
-- 【属主权限 + 每支自带 permission 列,外层一次性把关】(OPS-14 修法 (a))。
-- 本视图横跨六个模块,invoker 会让 RLS 把读者无权模块的行【静默丢掉】—— 行消失
-- 在这里意味着"那个数少算了",而不是报错。属主权限读全量,外层
-- WHERE has_permission(a.permission) 按【调用者】逐支裁决:无权的支【整支缺席】,
-- 不是零。谓词写一次而不是九遍 —— hr_alerts 的注释说过,复述 N 遍只会给下一个
-- 加支的人留一个漏写的机会;这里每支【声明】自己的权限码,外层【执行】它。
--
-- 【缺席 ≠ 零,页面必须自己分辨】视图对无权读者不发一行,于是"没有行"有两种
-- 含义:真的零,或者你看不见。app/page.tsx 先查权限再渲染每块牌子 —— 无权显示
-- 「受限」(common.restricted),绝不显示 0。这是仪表盘最容易犯、且任何 gate 都
-- 查不出的那个错(0 与"你看不见"在屏幕上一模一样 —— moduleGuard 的老病换了件衣服)。
--
-- 【item_type 写成 'x'::text 字面量】check-i18n 的 sqlLiteralAs 解析器现读本文件,
-- dashboard.item.* 的后缀集合就是这里的支列表 —— 加一支,键检查自动跟着变宽。
--
-- 【两笔贵的读数,按界所限】(OPS-16 报告点名的两处):
--   * fx_rate_gaps 按 (日期,币种) 对每组跑 fx_rate_asof,本身不受期间约束 ——
--     这里限 rate_date >= CURRENT_DATE - 45:仪表盘答"最近有没有漏",完整历史
--     归 /finance/month-end 按月翻。谓词落在分组键上,能下推进聚合。
--   * 银行对账这支【只数报表侧的未匹配行】(bank_statement_lines,行数 = 导入量,
--     天然有界)。bank_reconciliation_status 的账簿侧 LATERAL 要扫 journal_lines
--     全表 —— 那是对账页的活,不上人人都开的首页。
--
-- 【不在此列的】批次毛利 —— 有未决的设计问题(哪些限定词随数字走、已过账 COGS
-- 还是当前成本),自成一切,谓词已录在 AGENTS.md 常设决定 2。月结的七个信号 ——
-- /finance/month-end 是它们的枢纽,首页放一个入口,不复制信号。
--
-- NOTE: introduced by db/migrations/2026-08-09-ops18-operations-now-and-the-dashboard.sql.
-- EXEC-3a(2026-08-16):再【两】支 —— work_order_overdue 与
-- work_order_variance_beyond(WO-1c 记下的两个候选)。差异那一支的两个阈值
-- 现读 processing_settings,【两个数不是一个】(投入超耗是成本问题、
-- 产出短交是收率问题,合成一个数等于说它们一样严重)。
-- 【本刀一度加了资质那两支,而它们 CMP-2 就已经在了】—— 清单文件里那行
-- "Candidate, not built" 是过时的,重复分支由 fixture 37C 与 30A 当场抓住,
-- fu1 撤掉。见 db/migrations/2026-08-16-exec3a-fu1-*.sql。
-- 【batch_margin 撤了】:一个卖出去的批次毛利偏低是一个【状态】,没有清除动作 ——
-- 看板装的是待办,毛利的家是 /margin;可处理的那一半已经是 arm 15。
--
-- EXEC-1a(2026-08-16):两支高管臂 —— metal_quote_stale(行情陈旧,阈值现读
-- pricing_settings.metal_quote_stale_days,按 price_date 不按 created_at)与
-- orders_unfulfilled(confirmed / partially_shipped 的订单)。规格见
-- docs/dashboard-arm-inventory.md;【谁要看哪一支】见 docs/exec-views-plan.md。
--
-- OPS-19(2026-08-09):补上原始定稿漏掉的四支(awaiting_assay / batch_unpriced /
-- invoice_overdue / ar_over_90 + ap_over_90),并新增 output_unsold_aging —— sales
-- 这一行唯一够得着的支(它没有 module.finance.view,当初猜的 AR 支对它同样是「受限」)。
-- assay_unapplied 的粒度同时从"一份未执行化验一行"改成"一个批次一行",与
-- awaiting_assay 同源同粒度、互斥;live 该支当时为 0,故不改变任何现有数字。
--
-- ── SUP-TYPE-1a(2026-08-18):qualification_missing 收窄到【供货的】供应商 ──
-- EXEC-3a 在 2026-08-16-exec3a-four-executive-arms.sql:349 写着:判据是"一张都没有"
-- 而不是"缺某一类",因为没有一张"谁必须持哪张证"的要求矩阵;并且明写着
-- **"有了'这家需要合规文件'的标记之后,这一支应当收窄到它"**。
-- **那个标记现在有了(suppliers.supplies_goods),这一支已经收窄,那句话到此退休。**
-- 提交信息改不了历史文件,所以退休记录写在这里 —— 沿着引用走过来的人在这里落地。
--
-- 【为什么必须收窄:实测过的永久亮灯】SUP-TYPE-0 把它走了一遍:把一个只收钱、
-- 不供货的往来户沿合法路径推到 status='active',这一支当场亮起、days_waiting 一路
-- 长下去,而它永远不会灭 —— 房东不会去办危废证。收窄之后同样的走法【不再亮】,
-- 而一个没有证书的【真供应商】仍然照亮(fixture 89 两边都钉)。
--
-- CMP-1(2026-08-09):两支资质臂。qualification_expiring 到【类型自己的 lead days】就上牌,
-- 过期后【不落牌、无 -30 天下限】—— 工作证过期 30 天人已走,证书过期两年而进场仍可能,
-- 它就还站在那儿(live 那张 2024 年就过期的 Article 18 正是证据)。续期(valid_until
-- 前移)即安静。qualification_missing 是"一张证都没有"的缺席臂(与 awaiting_assay /
-- assay_unapplied 的分立同理)。disposition='ignore' 的类型不上牌。
-- 【规格在 docs/dashboard-arm-inventory.md】每一支是什么意思、挂哪个权限码、界在
-- 哪里、以及【哪些支被考虑过又被排除、为什么】都在那里。
-- 定稿只存在于一次对话里,代价是四支 —— 所以规矩是:
-- 【加一支 = 在同一个提交里往那份清单加一行】。
--
-- MAR-1(2026-08-10):支的权限从【一个码】放宽到【一个谓词】—— permission(必须有)
-- + permission_any(任意其一,由 arm_permission_any 一处声明,SELECT 与 WHERE 共用)。
-- 起因是批次毛利跨两个模块(prices AND (finance OR processing)),而没有任何 live 角色
-- 同时持有后两者。合成一个新权限码那条路被否掉:那会是谁能看毛利的第二份定义,
-- 与 batch_margin 自己的谓词必然漂开。fixture 45 三种读者各钉一次。
-- ASY-P1(2026-08-17):awaiting_assay 那一支【换了问题】。原来问的是"这个批次一份
-- 化验都没有"(batch_assay_status.assay_count = 0),它看不见"化验做了一半",
-- 也灭不掉料已耗尽那两盏灯(线上 IN-2026-0011 / IN-2026-0153,remaining_qty = 0)。
-- 现在读 batch_required_assay_gaps:物料声明了要验哪些金属、其中至少一种还没有被
-- 一份【已应用的】化验覆盖、并且【还取得到样】。subject 从供应商名换成【缺哪几种
-- 金属】—— subject 这一列在每一支里放的都是那一支最该让人看见的事实,而能让人
-- 下一步动起来的是缺哪几种。判据与理由住在那张视图里,不在这里。
-- LINKS-1(2026-08-11):每支多带一个 item_id —— 支从"指向一张列表"变成"指向那一件事"。
-- 【item_id 指的是谁】承载【补救动作】的那张页面所对应的行。十七支里它就是等待中的
-- 那一行;两支里是它的父:bank_unmatched(行没有页面,匹配动作在对账工作台上 →
-- 对账单)与 margin_cost_not_allocated(补救是给加工单分摊成本 → 加工单)。
-- 于是同一支的几行可以共用一个 item_id,那是对的,不是重复 —— fixture 47 因此断言
-- 的是"item_id 落在这一支该落的那张表里",不是"一行一个 id",也不是互不相同。
-- 【SO-3a:应收也成了两种单据】ar_over_90 的 doc_kind 从此非空('sale' 销售记录 /
-- 'invoice' 订单流发票),item_id 相应二选一 —— 门牌各是应收单据页与发票页,
-- app/page.tsx 按 doc_kind 分支,认不出的种类不给链接(与 ap 同一条)。
-- 【doc_kind 是披露】应付账款本来就是两种单据(ap_open_items 自己就按它分支,
-- 应付列表页也一直照它画链接),这张视图先前只是没说出口。其余十八支主体只有一种,
-- 该列为 NULL。【fx_rate_gap 没有 item_id】它的主体是一条不存在的牌价行,缺的东西
-- 没有 id —— 它指向按币种过滤的列表,那是"诚实过滤的列表"那类答案,不是按码搜索。
-- 每支的门牌与"补救是否在那张页面上"这条判据,写在 docs/dashboard-arm-inventory.md。
-- NOTE: item_id / doc_kind added by
-- db/migrations/2026-08-11-links1-operations-now-item-id.sql(列集变了 → DROP + CREATE)。
-- SS-1(2026-08-13):第二十支 safety_stock_below —— 物料的可用量低于它自己的
-- 安全库存阈值。【阈值 NULL 的物料一次都不响】:NULL 是"还没有人决定要盯它",
-- 不是"阈值为零",而把不响读成"查过了没问题"正是 METAL-1 的那一课。
-- 可用量来自 material_stock_available(一处求和,暂扣不算 —— 阈值问的是"还有多少
-- 能用的货",一次暂扣若能掩盖缺货,这个告警就在最该说话的时刻哑掉)。
-- item_date 用【最后一次库存移动】退回今天:阈值告警是持续状态,没有发生日;
-- 去算"哪天跌破的"要在首页翻整段流水史,那条界不允许(credit_over_limit 同形)。

-- LOG-5a(2026-08-20):第 23–26 支 —— 物流的四支告警。全部是【臂】(算出来、
-- 会自愈),不是 notifications 的事件。末尾的 WHERE 多了一个【放宽】算子
-- arm_permission_widen():它与收窄用的 arm_permission_any() 方向相反,
-- 对除 free_time_expiring 以外的每一支都返回 NULL(fixture 102G 逐支断言)。
-- LOG-5d(2026-08-20):同一种里程碑之内,算数的是【最后被录入】的那一条
-- (recorded_at DESC, id DESC)。此前按 event_date DESC 排,于是一条把日期
-- 改【早】的更正永远排不到前面、一次都不会生效(线上 CTR-2026-0009)。
-- EQP-2c(2026-08-21):第 27–28 支 —— 保养【到期】与【将到期】,两支不是一支。
-- 列契约一字未动。规格见 docs/dashboard-arm-inventory.md;推导与它的基线
-- (那两条"低读数有两种意思"的事实)整段写在 equipment_service_status 的视图注释里。
-- 【放宽】两支都走 arm_permission_widen(processing OR finance)—— 机器卡在财务、
-- 干活的人在加工,而它们底下每一张表/视图的读者都是这两个码的 OR。
CREATE OR REPLACE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))        UNION ALL
-- ── EXEC-3a:工单逾期 ──────────────────────────────────────────────────────
-- 【排产日为空【永远不是】逾期】—— 空的意思是"没排期",而不是"排在过去"。
-- 一个 COALESCE(scheduled_date, CURRENT_DATE) 会把没排期的全部报成今天到期,
-- COALESCE(..., 'infinity') 会把它们全部漏掉 —— 两个方向都错,所以这里
-- 显式 IS NOT NULL(WO-1c 记在 arm inventory 里的那条)。
--
-- 【"放行了三个月、从没排过期"该不该有别的支管】—— 仍然是一个【开着的问题】,
-- 记在 arm inventory 里。这一支不假装回答它:它只报"排了期而且过了期"的。
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text
            AND w.scheduled_date IS NOT NULL
            AND w.scheduled_date < CURRENT_DATE
        UNION ALL
-- ── EXEC-3a:工单差异超阈 ──────────────────────────────────────────────────
-- 【两种坏消息,两个阈值,两种触发时机】—— WO-1c 在 arm inventory 里留的那个
-- 问题("投入超耗与产出短交是否用同一个阈值")的答案是【不是】,所以
-- processing_settings 有两列,而这一支有两条腿:
--
--   * 投入超耗:吃掉的比计划多出 t_in% 以上。**开着的单和收了工的单都报** ——
--     超耗在它发生的那一刻就是可处理的事(料已经下去了,要么改计划、要么查为什么)。
--   * 产出短交:产出比预期少 t_out% 以上。**只报收了工的单** —— 在收工之前,
--     "少"只是"还没做完",把它报出来等于每天提醒一件正在进行的事。
--
-- 【没记录预期的行永远不报】has_plan = false 意味着没人估过,而不是估了零。
-- 一个把它当零的实现会让每一次产出都成为"短交 100%"—— 这正是 WO-1a 让
-- 预期产出行可选、WO-1b 让视图返回 NULL 的全部理由,在这里必须一路守住。
--
-- 阈值现读 processing_settings,不写死(与 metal_quote_stale 同一条)。
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
            CASE WHEN f.side = 'input'::text
                 THEN 'input overrun · ' || COALESCE(f.material_code, '?') || ' · '
                      || trim_scale(f.actual_qty)::text || ' / ' || trim_scale(f.planned_or_expected_qty)::text
                 ELSE 'output shortfall · ' || COALESCE(f.material_code, '?') || ' · '
                      || trim_scale(f.actual_qty)::text || ' / ' || trim_scale(f.planned_or_expected_qty)::text
            END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan
            AND f.planned_or_expected_qty > 0::numeric
            AND (
                 (f.side = 'input'::text
                  AND w2.status = ANY (ARRAY['released'::text, 'closed'::text])
                  AND f.actual_qty > f.planned_or_expected_qty
                      * (1::numeric + (SELECT ps.wo_input_overrun_pct FROM processing_settings ps LIMIT 1) / 100::numeric))
              OR (f.side = 'output'::text
                  AND w2.status = 'closed'::text
                  AND f.actual_qty < f.planned_or_expected_qty
                      * (1::numeric - (SELECT ps.wo_output_shortfall_pct FROM processing_settings ps LIMIT 1) / 100::numeric))
            )
        UNION ALL
-- ═══ LOG-5a:物流的四支 ═══════════════════════════════════════════════════
-- 【四支全部排除已软删的箱子】(c.deleted_at IS NULL,逐支各写一次)。
-- 【三个阈值 2 / 14 / 7 都是写死的(v1,Tim 定)】。要把它们变成可调的那一天,
-- 现成的先例是 certificate_types.warn_lead_days —— 一张 RUNTIME CONFIG 表,
-- 每一类自带提前期【和】后果(block/warn/ignore),"加一种是编辑一行,不是跑一次迁移"。
-- 在那之前,写死的数字至少是【看得见】的:它就在这里,不在某个配置项里。

-- ── 1 · 免柜期将尽 / 已超 ────────────────────────────────────────────────
-- 【锚点是"最后被【录入】的那条 arrived"】(LOG-5d 改)—— ORDER BY
-- recorded_at DESC, id DESC。**此前是 event_date DESC,那是错的**:
-- 里程碑只增不改,更正的写法是再记一条;而一条把日期改【早】的更正,
-- 在 event_date 排序下【永远排不到前面】,于是它一次都不会生效。
-- (线上实例 CTR-2026-0009:先录 arrived 08-16,再录一条更正 08-14 ——
--  所有读者仍然锚在 08-16。改晚的更正碰巧生效,改早的永远不生效。)
-- 【屏幕那一侧算的是同一件事,必须同刀改】页面为了显示剩余天数自己算了一遍
-- (app/logistics/containers/[id]/ContainerFreightPanel.tsx),口径一旦与这里分岔,
-- 屏幕写着"剩余 1 天"而看板一声不吭,且没有任何东西会报错。两处注释互相点名。
-- 【id DESC 是破平局的】recorded_at 默认 now() = 事务时刻,同一事务里插两条会一样;
-- uuid 比大小没有"更晚"的含义,但它是【确定的】—— 不确定比排错更坏。
-- 【这条规则只管"同一种里程碑里哪一条算数"】。跨类型的"现在走到哪一步"是另一个
-- 问题,仍按 event_date 排(container_overview.latest_milestone)—— 那里若改成
-- recorded_at,今天补录一条 booked 就会让箱子"退回"已订舱。
-- 【报价里 free_days 为 NULL 的箱子一支都不响】NULL = "这份报价没有写免柜期",
-- 与 0 =「零个免费天」是两件不同的事,而把前者当成后者会让每一个到港的箱子
-- 从第一天起就报警 —— 那是喊狼来了,而喊狼来了的告警等于没有告警。
         SELECT 'free_time_expiring'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((q.free_days - (CURRENT_DATE - arr.event_date))::text || ' left of '::text
              || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q
               ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id
              AND q.deleted_at IS NULL
              AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL
            AND q.free_days IS NOT NULL
            AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
-- ── 2 · 走了很久,没人说到了 ─────────────────────────────────────────────
-- 【这一支是上一支的保命companion】免柜期那一支只在【有 arrived】时才可能响;
-- 一个没人录到港的箱子,在那一支里【永远安静】,而安静与"没问题"在屏幕上
-- 长得一模一样(METAL-1 的 no_reference 那一课)。所以这一支专门说:
-- 开走 14 天了,而没有任何人说过它到了。
         SELECT 'container_no_arrival'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL
            AND (CURRENT_DATE - dep.event_date) >= 14
            AND NOT (EXISTS ( SELECT 1 FROM container_milestones m2
                               WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
-- ── 3 · 说好的到港日过了,而它还没到 ─────────────────────────────────────
-- 【expected_arrival_date 为 NULL 时这一支不响】,而那是一条【已知的局限】,
-- 不是一个疏漏:与 work_order_overdue 逐字同形(它也只报"排了期而且过了期"的,
-- 并在视图里明写"放行了三个月、从没排过期该不该有别的支管"仍是开着的问题)。
-- 同一个问题在这里原样成立:一个从来没人填过 ETA 的箱子,是"没问题",
-- 还是最该被问的那一个?这一支不假装回答它。
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL
            AND c.expected_arrival_date IS NOT NULL
            AND c.expected_arrival_date < CURRENT_DATE
            AND NOT (EXISTS ( SELECT 1 FROM container_milestones m3
                               WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
-- ── 4 · 开走了,单据还欠着 ───────────────────────────────────────────────
-- 【锚在 departure_date】—— 它是箱子上唯一 NOT NULL 的世界侧日期,所以一定算得出来。
-- 【代价照直写】:有些单据(订舱确认、装箱单)本该在开航【之前】就到,
-- 以开航日为零点会让它们永远不迟。这一支因此不是"所有该到的单据"的告警,
-- 是"开航之后还欠着"的告警 —— 名字与它测的东西一致。
-- 【从没实例化过清单的箱子一支都不响】:pending 数为 0,这里就没有行。
-- 那种"空"与"都收齐了"在库里长得一样,而把它们分开是 5b 的事(屏幕上说清哪一种空)。
         SELECT 'container_documents_late'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL
            AND p.n > 0
            AND (CURRENT_DATE - c.departure_date) >= 7
        UNION ALL
-- ── EQP-2c · 保养到期,以及【将到期】——【两支,不是一支带等级】────────────
-- operations_now 的列契约里没有"严重程度"这一列,所以唯一在结构上分得开的
-- 办法就是两个 item_type。与 qualification_expiring / qualification_missing、
-- container_no_arrival / container_eta_overdue 同形。
-- 【两支互斥】已到期的不再出现在"将到期"里(is_approaching 自己带 NOT is_due)
-- —— 否则同一件事被数两遍,那正是 fixture 30 那句话要抓的东西。
-- 【提前量是【数据】】lead_kg / lead_days 在 equipment_service_intervals 的行上,
-- 视图现读;fixture 111 F6 在同一笔事务里两个方向都验过。
-- 【item_id 是机器,不是间隔行】判据是 LINKS-1 那一条:门牌指向【承载补救动作】
-- 的那张页面所对应的行。补救动作是"给这台机器记一次保养",而它发生在机器那一页
-- (/finance/assets/[id],EQP-1c-b 建的)—— 间隔行今天没有自己的页面。
-- 与 bank_unmatched / margin_cost_not_allocated 取父行是同一条规矩。
-- 【item_date 是基线日】= 上一次那一种保养,没有就是取得日。于是
-- days_waiting 读出来就是"距上一次保养多少天",【正好就是两个量度里的天数那一个】,
-- 不是第三个数。
-- 【未监控的机器一支都不响,而那是一个具名状态不是零】判据 s.monitored ——
-- 理由整段写在 equipment_service_status 的视图注释里,这里不复述。
-- 【已处置的机器不收】一件"去保养它"的待办,对一台已经不在的机器没有意义。
-- 【牌子在 EQP-2d】本刀落的是这两支的【行】;首页那两块牌子在 2d。
         SELECT 'equipment_service_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess.equipment_code AS item_code,
            (ess.service_kind || ' — '::text) || ess.equipment_description AS subject,
            ess.baseline_date AS item_date
           FROM equipment_service_status ess
          WHERE ess.monitored AND ess.disposition = 'warn'::text AND ess.equipment_status <> 'disposed'::text AND ess.is_due
        UNION ALL
         SELECT 'equipment_service_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess_1.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess_1.equipment_code AS item_code,
            (ess_1.service_kind || ' — '::text) || ess_1.equipment_description AS subject,
            ess_1.baseline_date AS item_date
           FROM equipment_service_status ess_1
          WHERE ess_1.monitored AND ess_1.disposition = 'warn'::text AND ess_1.equipment_status <> 'disposed'::text AND ess_1.is_approaching
        UNION ALL
-- ★【CHASE-1:到期没兑现的承诺】★ 一个记下来却没有人被提醒的承诺,
-- 就是表里的一条备注。【它清得掉】谓词含 outcome IS NULL —— record_promise_outcome
-- 一记结局这一行就消失;一个清不掉的告警会教会人忽略告警(hr_alerts 那次)。
-- 【逾期就在承诺日【当天】】(Tim 2026-08-28 裁定,fu2 改的)——
-- 这门生意的货款通常在【下午中段】到账,所以承诺日当天来看这张单子的人,
-- 面对的已经是那天要处理的那件事;推到第二天等于让单子在它最有用的那一天沉默。
         SELECT 'promise_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            ps.promise_id AS item_id,
            NULL::text AS doc_kind,
            ps.chase_code AS item_code,
            ps.customer_name AS subject,
            ps.promised_date AS item_date
           FROM collection_promise_status ps
          WHERE ps.is_overdue
        UNION ALL
-- ★【WHT-1:到期没汇给 IRAS 的预提税】★ 当月代扣的税,**次月 15 日**前申报并缴纳。
-- 【这个日期与 CPF 的次月 14 日不是同一个数】各自来自各自的法令 —— 一个凑整过的
-- 法定期限,是一个会让公司逾期的数字,所以两处各写各的,不共用常量。
-- 【它清得掉,而清除【只能】由钱来完成】谓词读的是 wht_liability_by_month
-- 的 unremitted_base,而那个数只有在 remit_wht 过了一张真的分录、把 2150 借掉
-- 之后才会下降。**没有"知道了"按钮** —— 与 CPF 的 cpf_paid_at、与 CHASE-1 的
-- outcome IS NULL 是同一条:一个点一下就消失的告警,清除的是人的注意力,
-- 不是那件事;而一个清不掉的告警会教会人忽略告警(hr_alerts 那次)。
-- 【七天窗口取自 cpf_due 那一支】到期前七天开始响,逾期后继续响(差值为负)。
-- 【代扣为零的月份一支都不响】unremitted_base > 0 —— 而那不是"还没到",
-- 是"这个月没有代扣过任何税",一个正当且常见的状态。
         SELECT 'wht_due'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            to_char(w.period_month::timestamp, 'YYYY-MM'::text) AS item_code,
            -- 【币种是数据,不是字面量】本位币从 currencies.is_base 读 —— 这条
            -- 规矩有一支专门的检查(check-currency-literals),而它也看得见 SQL。
            (to_char(w.unremitted_base, 'FM999G999G990D00'::text) || ' '::text)
                || (SELECT c.code FROM currencies c WHERE c.is_base) AS subject,
            w.due_date AS item_date
           FROM wht_liability_by_month w
          WHERE w.unremitted_base > 0::numeric
            AND (w.due_date - CURRENT_DATE) <= 7
) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type)))
    AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

GRANT SELECT ON public.operations_now TO authenticated;


COMMIT;
