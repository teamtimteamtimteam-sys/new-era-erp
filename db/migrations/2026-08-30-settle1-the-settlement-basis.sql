-- SETTLE-1:结算口径 —— **四条条款是同一条公式里的四项**,一次做完。
--
-- 销售重量基准(G25)· 按买方化验最终结算(G23)· 化验方轴的【谁说了算】(U12)
-- · 精炼费(G20)与有害元素惩罚(G21)—— 合并是刻意的:它们在
-- index-pricing-spec §3 的那条公式里彼此相邻,拆开做会把一条公式拆成四次半成品。
--
-- ★★【本刀【记下决定】,它【不过账】】★★
--   sales_settlements 记的是:这次结算**用了谁的化验、按哪种重量基准、
--   依据哪一份冻结的条款**,以及算出来的金额与逐项拆解。
--   **一分钱都不进总账。** 两个各自独立的理由:
--     ① 会计政策 **5.7 自己标着 NOT BUILT** —— 差额科目已裁定,过账路径没有;
--     ② PRICE-1 **声明过它的断点**,两阶段开票还不存在 ——
--        **没有开票,就没有东西可以喂给一条过账路。**
--   所以不要把"结算上线了"读成"结算会过账"。
--
-- ★★【本刀的中心句,三张表都是它的实例】★★
--   **【没有声明】与【声明了"没有"】是两个不同的事实,而只有后者可以拿来算。**
--   assay_results.weight_basis 早就在用它(PROC-6:留空 = 没人说过);
--   本刀把它推到精炼费与惩罚的口径声明上。
--
-- 【本刀只加不删】新表四张、新函数三支、既有表加一列(可空有默认)、
--   一支既有函数 CREATE OR REPLACE(签名不变)。**没有 DROP、没有 RENAME。**
--   依赖清点:contract_document_terms **没有** _masked 孪生视图(实测),
--   所以那一列不触发 WO-1a 的"三件一起";flat_discount_pct **一个字都没动**
--   (它有活着的使用者,而 FIN-27 的已承诺副本必须保持原义)。

BEGIN;

-- ═══ 0. 触发器要用的守卫函数(必须先于建表)════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_sales_settlement_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- SETTLE-1:一条结算记录写下来之后就不可改 —— 除了被标成【被取代】那一列。
-- 理由:它是一次**要过钱的陈述**。就地改它会毁掉"当初要的是什么"这个记录,
-- 而那正是 guard_pricing_commitment_immutable 守着同一件事的原因。
-- 改正的办法是**再写一行**,并把旧的这一行的 superseded_by 指过去。
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SETTLEMENT_IMMUTABLE|delete'
          USING HINT = '结算记录不能删 —— 要改正,写一条新的并把这一条标成被取代';
    END IF;
    IF NEW.superseded_by IS DISTINCT FROM OLD.superseded_by
       AND to_jsonb(NEW) - 'superseded_by' = to_jsonb(OLD) - 'superseded_by' THEN
        RETURN NEW;   -- 只动了 superseded_by,那是允许的那一次改动
    END IF;
    RAISE EXCEPTION 'SETTLEMENT_IMMUTABLE|update'
      USING HINT = '结算记录只有 superseded_by 改得动 —— 要改正金额或依据,写一条新的';
END
$function$;

COMMENT ON FUNCTION public.guard_sales_settlement_immutable() IS
    'SETTLE-1:结算记录不可改(只有 superseded_by 一列动得了)。**它是一次要过钱的陈述**,就地改会毁掉「当初要的是什么」这个记录 —— 与 guard_pricing_commitment_immutable 同一条先例。改正 = 再写一行 + 把旧的标成被取代。';

-- ═══ 1. 结算口径:合同的第五个兄弟 ═══════════════════════════════════
-- db/tables/contract_settlement_terms.sql
-- SETTLE-1:结算口径 —— **一份合同一行**,合同的第五个兄弟子表。
--
-- 【位置照 CONTRACT-1 与 PRICE-1 的先例】条款是**兄弟子表**,不是 contracts 上
--   越加越多的列;而**冻结的时刻是【挂接】**,与品位规格、计价条款同一次动作 ——
--   **一份合同不许有两套冻结语义**(PRICE-1 第二轮为这件事拒过一个更"精确"的方案)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★【本表的中心句,四条列都是它的实例】★★★
--
--   **【没有声明】与【声明了"没有"】是两个不同的事实,而只有后者可以拿来算。**
--
--   这不是一句格言,它是 `assay_results.weight_basis` 已经在用的那条(PROC-6:
--   留空 = 没有人说过,而不是"按惯例是干基")。本表把同一条推到另外三处:
--     · sale_weight_basis        —— 结算按湿基还是干基,**必须声明**(NOT NULL)
--     · refining_charge_basis    —— 'none_agreed' 是一次**声明**,不是一次留空
--     · penalty_basis            —— 同上
--   于是"这份合同没有精炼费"是一个**记录下来的决定**,而不是"没人填过"。
--
-- 【为什么不让"没有子行"直接当成零 —— 后果是具体的】
--   黑粉承购里**精炼费近乎普遍**(proc-reality 的加工访谈)。把"没有子行"读成
--   "没有精炼费",会算出一张**看起来完全正常、而金额是错的发票** ——
--   **不是任何人会注意到的那种错误**。这正是本仓库反复清理的"静悄悄的默认值"。
--
-- 【为什么也不让"没有子行"一律拒 —— 那会教人绕过它】
--   一份**真的没有精炼费**的合同必须仍然结算得了。
--   **一条在正当情形上开火的拒绝,教会的是绕过它的办法**,而不是安全(WHT-1 那一课)。
--

CREATE TABLE public.contract_settlement_terms (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,

    -- ── 结算按哪种重量 ── ★ 必须声明,永远不给默认值 ★
    --   GO-3 量过:全库【只有】guard_assay_basis_stated 与 record_assay_result
    --   提到 weight_basis,**没有任何计价或结算函数按它分支** —— 于是一张按干基
    --   出的化验单被乘在湿重上,含金属被**高估**,而没有任何东西会响。
    --   那是一个**钱的错误**,不是一个政策缺口。
    sale_weight_basis text NOT NULL
        CHECK (sale_weight_basis IN ('as_received', 'dry')),

    -- ── 谁的化验说了算 ── U12 的那条条款(返回条件写的正是"第一份写明化验条款的合同")
    --   'umpire' **不在这里**:仲裁是一次**升级**,不是一份合同的常设约定。
    --   哪一份结果真的被用了,记在 sales_settlements 上,而不是从这里推导。
    settling_party text NOT NULL
        CHECK (settling_party IN ('ours', 'counterparty')),

    -- ── 分歧容差(splitting limit)── ★ 可空,而【空永远不会变成一个决定】★
    --   Tim 2026-08-29 裁定:争议**送第三方独立检测机构复检**。那条裁定命名的是
    --   **升级路径**,不是一个阈值 —— 所以容差**没有人裁过**,这一列留空是常态。
    --   ★【为什么系统【不】按它自动选】★ 让系统按容差自动选,等于**让系统决定
    --   谁的数字是钱**;而容差为空时,它还得**编一个默认值**才做得到那件事。
    --   所以:容差只用来**指出**两份结果差得超过了它,**永远不自己选**。
    --   两份结果有分歧、又没有声明容差时,结算**按名拒**,并说出该做什么。
    splitting_limit_pct numeric
        CHECK (splitting_limit_pct IS NULL OR (splitting_limit_pct > 0 AND splitting_limit_pct <= 100)),

    -- ── 留样【义务】── 这是一条**合同条款**;留样这件**实物**不在本刀射程内。
    --   ★【一个说出来的未满足前提,而不是一个沉默的】★
    --   Tim 的裁定要求争议时送第三方复检,而**第三方复检要有一个罐子** ——
    --   这套系统今天**说不出某个样品还在不在**(只有 assay_results.sample_ref
    --   一段自由文本)。留样的实物模型是**实验室工作流**那一件(proc-reality N26),
    --   与本刀同源但不同件。**所以这里记的是"合同要不要求留样",不是"样品在哪"。**
    sample_retention_required boolean NOT NULL,
    -- 留多久也是一条条款;没约定就是 NULL,同样不给默认值。
    sample_retention_days integer
        CHECK (sample_retention_days IS NULL OR sample_retention_days > 0),

    -- ── 精炼费与惩罚元素的【口径声明】── 见抬头那条中心句
    --   'none_agreed' = 这份合同**声明了没有**;'per_metal'/'per_element' = 有,
    --   而具体数值在子表里。声明了有、子表却是空的 → 结算**按名拒**。
    refining_charge_basis text NOT NULL
        CHECK (refining_charge_basis IN ('none_agreed', 'per_metal')),
    penalty_basis text NOT NULL
        CHECK (penalty_basis IN ('none_agreed', 'per_element')),

    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    -- 一份合同一套结算口径
    CONSTRAINT contract_settlement_terms_one_per_contract UNIQUE (contract_id)
);

CREATE INDEX idx_contract_settlement_terms_contract
    ON public.contract_settlement_terms (contract_id);

ALTER TABLE public.contract_settlement_terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract settlement terms select by owner permission"
    ON public.contract_settlement_terms AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract settlement terms write by owner permission"
    ON public.contract_settlement_terms AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_settlement_terms IS
    'SETTLE-1:结算口径 —— 合同的第五个兄弟子表,一份合同一行,冻结时刻与品位规格/计价条款相同(挂接那一刻),**一份合同不许有两套冻结语义**。★★**本表的中心句**★★:**【没有声明】与【声明了"没有"】是两个不同的事实,而只有后者可以拿来算。** 那正是 assay_results.weight_basis 已经在用的规矩(PROC-6:留空 = 没人说过),本表把它推到精炼费与惩罚的口径声明上 —— refining_charge_basis = ''none_agreed'' 是一次**声明**,不是一次留空。★**为什么不让"没有子行"当成零**★:黑粉承购里精炼费近乎普遍,把没有子行读成没有精炼费,会算出一张**看起来完全正常而金额是错的发票**,不是任何人会注意到的那种错误。★**为什么也不一律拒**★:一份真的没有精炼费的合同必须仍然结算得了 —— 一条在正当情形上开火的拒绝,教会的是绕过它的办法。★**splitting_limit_pct 可空,而空永远不会变成一个决定**★:让系统按容差自动选,等于**让系统决定谁的数字是钱**,而容差为空时它还得**编一个默认值**才做得到 —— 所以它只用来指出差距,永远不自己选;有分歧又没声明容差时结算按名拒。★**留样**★:这里记的是**合同要不要求留样**(一条条款),不是样品在哪 —— 实物模型属于实验室工作流(N26),**而它今天不存在,所以仲裁路径有一个【说出来的】未满足前提:第三方复检要有一个罐子,而系统说不出某个样品还在不在**。';

COMMENT ON COLUMN public.contract_settlement_terms.sale_weight_basis IS
    'SETTLE-1:结算按湿基(as_received)还是干基(dry)。**必须声明,永远不给默认值。** GO-3 量过:全库只有 guard_assay_basis_stated 与 record_assay_result 提到 weight_basis,**没有任何计价或结算函数按它分支** —— 于是一张按干基出的化验单被乘在湿重上,含金属被高估,而没有任何东西会响。**那是一个钱的错误,不是一个政策缺口。**';

COMMENT ON COLUMN public.contract_settlement_terms.settling_party IS
    'SETTLE-1:哪一方的化验结果用于最终结算(U12 那条条款;它的返回条件写的正是「第一份写明化验条款的合同」,而本刀建的就是那个)。★**''umpire'' 不是这里的合法值**★:仲裁是一次**升级**,不是一份合同的常设约定。**哪一份结果真的被用了,记在 sales_settlements 上** —— 那是一次被记录的选择,不是从本列推导出来的。';

-- ═══ 2. 精炼费(按【含金属】吨数)════════════════════════════════════
-- db/tables/contract_refining_charges.sql
-- SETTLE-1:精炼费(RC)—— **按【含金属】的吨数收**,逐金属一行。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【它为什么不能用现成的 flat_discount_pct 冒充】★★
--   `pricing_formulas.flat_discount_pct` 是**按 gross 的比例**走的;
--   而 RC 是**按含金属单位**收、**与价格无关**。两者形状不同,后果很具体:
--   **拿折扣冒充 RC,价格一动那个数字就错**(proc-reality 那条访谈结论)。
--   所以本刀**不碰** flat_discount_pct:它有活着的使用者,而 FIN-27 的
--   已承诺副本必须保持它们当初的含义;动它还会碰到采购侧,而采购侧
--   是 index-pricing-spec §9 留给 Tim 的问题。
--
--   顺带把另一件分清楚:`treatment_charge_usd_per_tonne`(TC)是**按物料吨数**收的,
--   RC 是**按含金属吨数**收的 —— 两者都存在、都正当,而它们**吨的主语不同**。
--   这一条区别正是本刀 4.4 那一臂能证明"湿基与干基结算出不同金额"的原因:
--   **按物料吨数的费用随基准变,按含金属吨数的费用不变。**
--
-- 【值是未知的,而轴是现在就该建的】Tim **没有**给条款清单,所以本表出厂**是空的**。
--   本仓库那条标准区分:**轴(一列,事后加很贵)现在建;值(行,很便宜)留着。**
--   而"空"不许被读成"没有精炼费" —— 那由 contract_settlement_terms.refining_charge_basis
--   来说(见那张表的中心句)。
--

CREATE TABLE public.contract_refining_charges (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 与 contract_pricing_terms.metal / assay_result_metals.metal 同一个字典
    metal        text NOT NULL REFERENCES public.substances (code),
    -- ★ 单位:每【含金属】吨多少美元 —— 列名把主语写进去,免得下一个人读成物料吨
    usd_per_tonne_of_metal numeric NOT NULL CHECK (usd_per_tonne_of_metal >= 0),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT contract_refining_charges_one_per_metal UNIQUE (contract_id, metal)
);

CREATE INDEX idx_contract_refining_charges_contract
    ON public.contract_refining_charges (contract_id);

ALTER TABLE public.contract_refining_charges ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract refining charges select by owner permission"
    ON public.contract_refining_charges AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract refining charges write by owner permission"
    ON public.contract_refining_charges AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_refining_charges IS
    'SETTLE-1:精炼费(RC),**按【含金属】吨数收**,逐金属一行。★**它不能用 flat_discount_pct 冒充**★:那一列按 gross 的**比例**走,而 RC 按**含金属单位**收、与价格无关 —— **拿折扣冒充 RC,价格一动那个数字就错**。本刀因此**不碰** flat_discount_pct(它有活着的使用者,FIN-27 的已承诺副本必须保持原义;动它还会碰到采购侧,而那是 index-pricing-spec §9 留给 Tim 的)。顺带分清另一件:`treatment_charge_usd_per_tonne`(TC)按**物料**吨数收,RC 按**含金属**吨数收 —— **两者吨的主语不同**,而这正是湿基与干基会结算出不同金额的原因(按物料吨数的费用随基准变,按含金属吨数的不变)。★**值未知、轴现在建**★:Tim 没有给条款清单,本表出厂是空的;而**空不许被读成"没有精炼费"** —— 那由 contract_settlement_terms.refining_charge_basis 来说。';

-- ═══ 3. 有害元素惩罚(按【结算重量】吨数)════════════════════════════
-- db/tables/contract_penalty_elements.sql
-- SETTLE-1:有害元素惩罚 —— **物质 + 阈值 + 费率**,三样都是合同条款,逐物质一行。
--
-- 【前置条件已经完成】惩罚要指名一种物质,而物质字典(`substances`)是
--   PROC 那一刀记下的前置条件,今天 7 条全部在册 —— 所以这一张挂得上外键,
--   而不是又一列自由文本(F7 那条规律:自由文本迟早要变字典,而拖延很贵)。
--   黑粉承购里**首推的两个惩罚元素是氟与氯**(proc-reality 的访谈),
--   而**它们今天不在 substances 里** —— 见下面那条注释,那是一个具名的缺席。
--
-- ★★【费率的形状是【一种】写法,而不是唯一一种 —— 说出来,不假装】★★
--   本表表达的是:**超过阈值之后,每超 1 个百分点、每吨结算重量收多少美元**。
--   真实合同还有别的写法(整段阶梯、封顶、按批一口价)。**Tim 没有给条款清单**,
--   所以本刀**只建这一种**,并把这句话写在这里 —— 下一个拿到真合同的人
--   要么发现它够用,要么知道该在哪儿加,而不是以为这就是全部。
--
-- ★【惩罚按【结算重量】收,所以它随湿基/干基变】★
--   这与 RC 相反(RC 按含金属吨数,含金属是不变量)。两条合起来才解释了
--   为什么同一批货按湿基与按干基结算出**不同的金额** —— 而那正是 GO-3
--   点名的那个"钱的错误"之所以是钱的错误。
--

CREATE TABLE public.contract_penalty_elements (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 指名一种物质 —— 外键,不是自由文本
    substance    text NOT NULL REFERENCES public.substances (code),
    -- 超过这个含量(%)才开始罚
    threshold_pct numeric NOT NULL CHECK (threshold_pct >= 0 AND threshold_pct <= 100),
    -- 每超 1 个百分点、每吨【结算重量】多少美元
    usd_per_tonne_per_pct_over numeric NOT NULL CHECK (usd_per_tonne_per_pct_over >= 0),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT contract_penalty_elements_one_per_substance UNIQUE (contract_id, substance)
);

CREATE INDEX idx_contract_penalty_elements_contract
    ON public.contract_penalty_elements (contract_id);

ALTER TABLE public.contract_penalty_elements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract penalty elements select by owner permission"
    ON public.contract_penalty_elements AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract penalty elements write by owner permission"
    ON public.contract_penalty_elements AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_penalty_elements IS
    'SETTLE-1:有害元素惩罚 —— **物质 + 阈值 + 费率**,三样都是合同条款,逐物质一行。前置条件(substances 字典)已完成,所以这里挂的是**外键而不是又一列自由文本**(F7:自由文本迟早要变字典,拖延很贵)。★★**费率的形状是【一种】写法,不是唯一一种**★★:本表表达「超过阈值后,每超 1 个百分点、每吨**结算重量**收多少美元」;真实合同还有阶梯、封顶、按批一口价等写法 —— **Tim 没有给条款清单**,所以本刀只建这一种,并把这句话写在这里,好让下一个拿到真合同的人知道该在哪儿加,而不是以为这就是全部。★**惩罚按结算重量收,所以它随湿基/干基变**★(与 RC 相反,RC 按含金属吨数、而含金属是不变量)—— 两条合起来解释了为什么同一批货按湿基与按干基结算出**不同的金额**。★**具名的缺席**★:访谈点名的头两个惩罚元素是**氟与氯**,而它们**今天不在 substances 里**(在册 7 条:al/co/cu/fe/li/mn/ni)—— 所以一条氟或氯的惩罚条款**今天填不进来**,那不是本表的缺陷,是字典还缺两行。';

COMMENT ON COLUMN public.contract_penalty_elements.usd_per_tonne_per_pct_over IS
    'SETTLE-1:每超阈值 1 个百分点、每吨【结算重量】多少美元。**「结算重量」= contract_settlement_terms.sale_weight_basis 选定的那个重量**(湿基取毛重,干基取扣水后重量)—— 所以**同一份惩罚条款在两种基准下收出不同的钱**,而那是对的:罚的是随货一起进来的杂质,而水也是随货一起进来的。';

-- ═══ 4. 结算记录(记决定,不过账)════════════════════════════════════
-- db/tables/sales_settlements.sql
-- SETTLE-1:一次销售最终结算的**记录** —— 它记下决定,**它不过账**。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【这一行【能】做什么、【不能】做什么 —— 免得"结算上线了"被读成"结算会过账"】★★
--   **能**:记下这一次结算**用了谁的化验、按哪种重量基准、依据哪一份冻结的条款**,
--         并把金额与逐项拆解算出来存下。
--   **不能**:**它一分钱都不进总账。** 没有暂定价发票、没有最终结算单据、
--         没有差额分录。
--   两个各自独立的理由:
--     ① 会计政策 **5.7 自己标着 NOT BUILT** —— 差额的科目已裁定(计入原收入科目),
--        而**没有过账路径**;在它之前落一条过账路,就是越过那个标记。
--     ② PRICE-1 **声明过它的断点**(停在规格 §7 第 2 步之后),
--        两阶段开票还不存在 —— 而**没有开票,就没有东西可以喂给一条过账路**。
--
-- ★★【为什么"哪一份化验说了算"必须【记】,不能【推】】★★
--   诱惑是从 `assay_results.applied_at` 推:那一份被 apply 过,那就是它。
--   **那是错的,而且是本仓库已经点名过的那种错**:`applied_at` 说的是
--   **"这份化验被应用到批次的成分上"** —— 那是一个**成分事实**,
--   不是一次**结算决定**。拿前者冒充后者,正是 F6 警告的那种 supersession 滥用,
--   而 F6 明说那会**销毁我们自己的数**。所以这里有一列 assay_result_id,
--   它是**被写下来的选择**。
--
-- ★【与 F6 的边界,写在这里免得两段读起来互相矛盾】★
--   F6 警告的是:拿 supersession 去表示**另一方的**结果(把对手方的化验
--   记成"我们复验了")。`result_party` 轴(PROC-6 建的)让那件事**不再必要**。
--   本表的 superseded_by 纠正的是**我们自己的那一句陈述**(算错了、选错了结果),
--   **它不夹带别人的结果** —— 两者主语不同,不冲突。
--
-- 【不可改】写下来之后就是一次**要过钱的陈述**;就地改它会毁掉"当初要的是什么"
--   这个记录。改正的办法是**再写一行并把旧的标成被取代** —— 与
--   guard_pricing_commitment_immutable 同一条先例(全库已有 27 道同族守卫)。
--

CREATE TABLE public.sales_settlements (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 三样都记,理由见抬头:条款在销售单上、金属与水分在产出批次的化验上
    sales_order_id   uuid NOT NULL REFERENCES public.sales_orders (id) ON DELETE RESTRICT,
    output_batch_id  uuid NOT NULL REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    -- ★ 被写下来的那个选择 ★
    assay_result_id  uuid NOT NULL REFERENCES public.assay_results (id) ON DELETE RESTRICT,

    -- ── 用了什么(抄下来的值,不是回查得到的指针)─────────────────────────
    settling_party_used  text NOT NULL
        CHECK (settling_party_used IN ('ours', 'counterparty', 'umpire')),
    weight_basis_used    text NOT NULL
        CHECK (weight_basis_used IN ('as_received', 'dry')),
    gross_weight_kg      numeric NOT NULL CHECK (gross_weight_kg > 0),
    -- 只在需要换算时才有值;换算需要它而它为空时,结算按名拒
    moisture_pct         numeric CHECK (moisture_pct IS NULL OR (moisture_pct >= 0 AND moisture_pct < 100)),
    settlement_weight_kg numeric NOT NULL CHECK (settlement_weight_kg > 0),

    -- ── 算出来的钱 ──────────────────────────────────────────────────────
    metal_value_usd      numeric NOT NULL,
    refining_charge_usd  numeric NOT NULL CHECK (refining_charge_usd >= 0),
    penalty_usd          numeric NOT NULL CHECK (penalty_usd >= 0),
    amount_usd           numeric NOT NULL,
    -- 逐项拆解:每种金属的含量/应付量/单价/金额,以及每一条惩罚是怎么来的。
    -- 【它让这个金额可以被【重导出】,而不是被相信】—— 与 PRICE-1 的 legs 同一条。
    breakdown            jsonb NOT NULL,
    -- 算它时依据的那一份【冻结的条款副本】,原样存下
    terms_snapshot       jsonb NOT NULL,

    -- 改正 = 新写一行 + 把旧的标成被取代(见抬头与 F6 的边界)
    superseded_by        uuid REFERENCES public.sales_settlements (id),

    computed_at      timestamptz NOT NULL DEFAULT now(),
    computed_by      uuid DEFAULT auth.uid(),
    CONSTRAINT sales_settlements_breakdown_is_object CHECK (jsonb_typeof(breakdown) = 'object'),
    CONSTRAINT sales_settlements_terms_is_object     CHECK (jsonb_typeof(terms_snapshot) = 'object'),
    -- 水分要么没有,要么与结算重量自洽 —— 见 sale_settlement_compute
    CONSTRAINT sales_settlements_no_self_supersede   CHECK (superseded_by IS NULL OR superseded_by <> id)
);

CREATE INDEX idx_sales_settlements_order  ON public.sales_settlements (sales_order_id);
CREATE INDEX idx_sales_settlements_batch  ON public.sales_settlements (output_batch_id);
CREATE INDEX idx_sales_settlements_assay  ON public.sales_settlements (assay_result_id);
-- 一张销售单 + 一个产出批次,**只有一行没有被取代的结算**
CREATE UNIQUE INDEX sales_settlements_one_live_per_order_batch
    ON public.sales_settlements (sales_order_id, output_batch_id)
    WHERE superseded_by IS NULL;

CREATE TRIGGER trg_sales_settlements_immutable
    BEFORE UPDATE OR DELETE ON public.sales_settlements
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_settlement_immutable();

ALTER TABLE public.sales_settlements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sales settlements select by customer permission"
    ON public.sales_settlements AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.customers.view'::text));
-- 【没有 INSERT/UPDATE 策略,而那是刻意的】写入只走 record_sale_settlement:
-- 检查与写入必须在同一笔事务里,否则分两步之间那道缝足够让一份不合口径的
-- 结算先被写下来(与 contract_document_terms 同一条理由)。

COMMENT ON TABLE public.sales_settlements IS
    'SETTLE-1:一次销售最终结算的**记录** —— **它记下决定,它不过账**。★**能/不能**★:能记下这次结算**用了谁的化验、按哪种重量基准、依据哪一份冻结条款**,并存下金额与逐项拆解;**不能**——**一分钱都不进总账**,没有暂定价发票、没有结算单据、没有差额分录。两个独立的理由:① 会计政策 **5.7 自己标着 NOT BUILT**(差额科目已裁定、过账路径没有),在它之前落过账路就是越过那个标记;② PRICE-1 **声明过断点**,两阶段开票还不存在,**没有开票就没有东西喂给过账路**。★★**为什么"哪一份化验说了算"必须记、不能推**★★:诱惑是从 assay_results.applied_at 推,而 **applied_at 说的是「这份化验被应用到批次成分上」——那是一个【成分事实】,不是一次【结算决定】**;拿前者冒充后者正是 F6 警告的 supersession 滥用,F6 明说那会**销毁我们自己的数**。★**与 F6 的边界**★:F6 警告的是拿 supersession 表示**另一方的**结果,而 result_party 轴让那件事不再必要;本表的 superseded_by 纠正的是**我们自己的那一句陈述**,**不夹带别人的结果** —— 主语不同,不冲突。★**不可改**★:写下来就是一次要过钱的陈述,就地改会毁掉「当初要的是什么」;改正 = 再写一行并把旧的标成被取代(全库已有 27 道同族守卫)。';

-- ═══ 5. 单据抄下来的那一份,多抄一段结算口径 ═════════════════════════════
-- 【为什么不触发"三件一起"】contract_document_terms **没有** _masked 孪生视图,
-- 也没有列清单 SELECT 授权(清点过,不是假定)——表级授权自动覆盖后加的列。
ALTER TABLE public.contract_document_terms
    ADD COLUMN settlement_terms jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.contract_document_terms
    ADD CONSTRAINT contract_document_terms_settlement_terms_is_object
        CHECK (jsonb_typeof(settlement_terms) = 'object');

COMMENT ON COLUMN public.contract_document_terms.settlement_terms IS
    'SETTLE-1:挂上去那一刻抄下来的**结算口径**快照 —— 一个**对象**(一份合同一套口径),里面装 contract_settlement_terms 那一行的值,**外加**它两张子表的行(精炼费 / 惩罚元素)。**三样一起冻**,因为结算靠它们一起算钱,而分开冻会让「我按哪一份算的」变成三个不同的时刻。**空对象 {} 合法**(合同可以没有结算口径),NULL 不合法 —— **「没有口径」与「没抄」必须分得开**。冻结的时刻与品位规格、计价条款相同:**挂接那一刻**,不是下单那一刻。';

-- ═══ 6. 挂接时把结算口径一并抄下 ═════════════════════════════════════
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
    v_settle   jsonb;
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

    -- SETTLE-1:结算口径连同它两张子表,**一起**抄下来。
    -- 【三样一起冻】结算要靠它们一起算钱;分开冻,"我按哪一份算的"就变成三个时刻。
    SELECT COALESCE(to_jsonb(x) - 'id' - 'contract_id' - 'created_at' - 'created_by'
                    - 'updated_at' - 'updated_by'
                    || jsonb_build_object(
                         'refining_charges', COALESCE((
                             SELECT jsonb_agg(jsonb_build_object(
                                 'metal', r.metal,
                                 'usd_per_tonne_of_metal', r.usd_per_tonne_of_metal) ORDER BY r.metal)
                               FROM contract_refining_charges r WHERE r.contract_id = v_con.id), '[]'::jsonb),
                         'penalty_elements', COALESCE((
                             SELECT jsonb_agg(jsonb_build_object(
                                 'substance', pe.substance,
                                 'threshold_pct', pe.threshold_pct,
                                 'usd_per_tonne_per_pct_over', pe.usd_per_tonne_per_pct_over) ORDER BY pe.substance)
                               FROM contract_penalty_elements pe WHERE pe.contract_id = v_con.id), '[]'::jsonb)),
                    '{}'::jsonb)
      INTO v_settle
      FROM contract_settlement_terms x WHERE x.contract_id = v_con.id;
    v_settle := COALESCE(v_settle, '{}'::jsonb);

    INSERT INTO contract_document_terms (
        purchase_order_id, sales_order_id, contract_id,
        contract_code, contract_title, incoterm, currency, payment_terms_days,
        grade_specs, pricing_terms, settlement_terms, linked_by)
    VALUES (
        CASE WHEN p_document_kind = 'purchase_order' THEN p_document_id END,
        CASE WHEN p_document_kind = 'sales_order'    THEN p_document_id END,
        v_con.id,
        v_con.code, v_con.title, v_con.incoterm, v_con.currency, v_con.payment_terms_days,
        v_specs, v_pricing, v_settle, auth.uid());

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
        'settlement_terms_copied', (v_settle <> '{}'::jsonb),
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

-- ═══ 7. 结算的算法(一处实现,两个调用者)════════════════════════════
CREATE OR REPLACE FUNCTION public.sale_settlement_compute(p_sales_order_id uuid, p_output_batch_id uuid, p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- SETTLE-1:一次销售最终结算的**算法** —— 四条条款是**同一条公式**里的四项。
--
-- ★★【一处实现,两个调用者】★★ 本支只**算**,不写;record_sale_settlement 调它
--   再落一行。本仓库为"两份实现在写下来那天一致、之后悄悄分开"付过**四次**账
--   (AGENTS.md 那条预览规则),所以预览与落库读的是同一段算术。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【公式(index-pricing-spec §3),四条条款各占一项】
--     (结算重量 × 含量 × 计价系数) × 计价期均价      ← 重量基准 / PRICE-1 的条款
--   − 精炼费(按【含金属】吨数)                       ← contract_refining_charges
--   − 惩罚(按【结算重量】吨数,超阈值部分)           ← contract_penalty_elements
--   而"用谁的化验"决定了上面的**含量**从哪一行来       ← result_party / settling_party
--
-- ★★【为什么湿基与干基结算出【不同的钱】】★★
--   含金属是**不变量**(换算对了的话,湿基算与干基算得到同一个含量),
--   所以**金属价值与精炼费不随基准变**。变的是**惩罚** ——
--   它按**结算重量**收,而水是随货一起进来的。
--   于是同一批货按湿基结算比按干基**多罚**,而那是对的。
--   **这也正是 GO-3 那个"钱的错误"之所以是钱的错误。**
--
-- 拒绝(全部按名,全部双语):
--   SETTLEMENT_PERMISSION_DENIED|<code>        没有权限(而不是让 RLS 报成"数据缺了")
--   SO_NOT_FOUND / OUTPUT_BATCH_NOT_FOUND / ASSAY_NOT_FOUND
--   SETTLEMENT_NO_CONTRACT_TERMS|<so>          这张单没挂合同,没有可依据的冻结条款
--   SETTLEMENT_TERMS_NOT_SET|<contract>        挂了合同,但那份合同没有结算口径
--   ASSAY_NOT_FOR_BATCH|<assay>|<batch>        选的化验不是这个批次的
--   ★ ASSAY_WEIGHT_BASIS_NOT_STATED|<assay>    化验没说按哪种重量报 ← 本刀最要紧的那条
--   ASSAY_PARTY_NOT_THE_SETTLING_PARTY|…       选的化验不是合同约定的那一方(仲裁除外)
--   RESULTS_IN_DISPUTE|…                       两方结果不一致,而没有声明容差
--   RESULTS_EXCEED_SPLITTING_LIMIT|…           不一致超过了声明的容差 → 该走仲裁
--   SETTLEMENT_MOISTURE_NOT_STATED|<assay>     要换算基准却没有水分
--   SETTLEMENT_PAYABLE_NOT_STATED|<metal>      没有计价系数(PRICE-1 的条款)
--   SETTLEMENT_BASE_EVENT_DATE_UNKNOWN|<event> 基准事件的日期在卖方向还记不下来
--   REFINING_CHARGE_NOT_FILED|<contract>|<metal>   声明了按金属收,却没填那一行
--   PENALTY_ELEMENTS_NOT_FILED|<contract>          声明了按元素罚,却一行都没填
DECLARE
    v_st        jsonb;     -- 冻结的结算口径
    v_pricing   jsonb;     -- 冻结的计价条款(PRICE-1)
    v_terms     record;
    v_batch     record;
    v_assay     record;
    v_basis     text;
    v_gross     numeric;
    v_moist     numeric;
    v_swt       numeric;   -- 结算重量
    v_other     record;
    v_lim       numeric;
    v_maxdiff   numeric;
    v_el        jsonb;
    v_ccode     text;
    v_pt_event  text;
    v_pt_months integer;
    v_pt_index  text;
    v_metal     text;
    v_content   numeric;
    v_content_s numeric;
    v_contained numeric;
    v_payable   numeric;
    v_pay_kg    numeric;
    v_price     numeric;
    v_qp        record;
    v_rc        numeric;
    v_base_date date;
    v_lines     jsonb := '[]'::jsonb;
    v_pens      jsonb := '[]'::jsonb;
    v_mv        numeric := 0;
    v_rcs       numeric := 0;
    v_pen       numeric := 0;
    v_thr       numeric;
    v_rate      numeric;
    v_over      numeric;
    v_amt       numeric;
BEGIN
    IF p_sales_order_id IS NULL OR p_output_batch_id IS NULL OR p_assay_result_id IS NULL THEN
        RAISE EXCEPTION 'SETTLEMENT_ARGUMENTS_REQUIRED';
    END IF;
    -- 【权限按名拒,不让 RLS 把行藏起来报成"数据缺了"】PRICE-1 的 fu1 是这一课,
    -- 这里一开始就写上,而不是等 fixture 再抓一次。
    IF NOT has_permission('module.customers.view'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.customers.view'
          USING HINT = '看得见销售结算要有客户模块的查看权限 —— 这不是数据缺失,是权限';
    END IF;

    -- ── 冻结的条款副本(【抄】,不回查合同现在怎么写)────────────────────────
    SELECT * INTO v_terms FROM contract_document_terms WHERE sales_order_id = p_sales_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SETTLEMENT_NO_CONTRACT_TERMS|%', p_sales_order_id
          USING HINT = '这张销售单没有挂在任何合同之下 —— 结算口径是合同条款,没有合同就没有口径';
    END IF;
    v_st := v_terms.settlement_terms;
    v_pricing := v_terms.pricing_terms;
    v_ccode := v_terms.contract_code;
    IF v_st IS NULL OR jsonb_typeof(v_st) <> 'object' OR v_st = '{}'::jsonb THEN
        RAISE EXCEPTION 'SETTLEMENT_TERMS_NOT_SET|%', v_ccode
          USING HINT = '这份合同没有结算口径(重量基准 / 谁的化验说了算 / 精炼费与惩罚的口径)—— 先在合同上写明,再重新挂接';
    END IF;

    SELECT * INTO v_batch FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'OUTPUT_BATCH_NOT_FOUND|%', p_output_batch_id; END IF;
    SELECT * INTO v_assay FROM assay_results WHERE id = p_assay_result_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', p_assay_result_id; END IF;
    IF v_assay.output_batch_id IS DISTINCT FROM p_output_batch_id THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOR_BATCH|%|%', v_assay.code, v_batch.code;
    END IF;

    -- ── ★ 化验必须说出它按哪种重量报 ★ ─────────────────────────────────────
    -- GO-3:一张按干基出的化验单被乘在湿重上,含金属被**高估**,而没有任何东西会响。
    -- **留空 = 没有人说过**,而不是"按惯例是干基" —— 所以这里拒,不猜。
    IF v_assay.weight_basis IS NULL THEN
        RAISE EXCEPTION 'ASSAY_WEIGHT_BASIS_NOT_STATED|%', v_assay.code
          USING HINT = '这份化验没有说明它按湿基还是干基报 —— 而两者会结算出不同的金额,所以不能猜';
    END IF;

    -- ── 谁的化验说了算 ────────────────────────────────────────────────────
    -- 仲裁结果【总是】可以结算:它是那条升级路径的终点。
    IF v_assay.result_party <> 'umpire'
       AND v_assay.result_party IS DISTINCT FROM (v_st->>'settling_party') THEN
        RAISE EXCEPTION 'ASSAY_PARTY_NOT_THE_SETTLING_PARTY|%|%|%',
            v_assay.code, v_assay.result_party, (v_st->>'settling_party');
    END IF;

    -- ── 两方结果不一致时,【系统不自己选】────────────────────────────────
    -- ★ 让系统按容差自动选,等于让系统**决定谁的数字是钱**;而容差为空时,
    --   它还得**编一个默认值**才做得到那件事。所以:指出,不选。
    IF v_assay.result_party <> 'umpire' THEN
        SELECT a.code, a.id INTO v_other
          FROM assay_results a
         WHERE a.output_batch_id = p_output_batch_id AND a.deleted_at IS NULL
           AND a.id <> p_assay_result_id
           AND a.result_party IN ('ours', 'counterparty')
           AND a.result_party <> v_assay.result_party
         ORDER BY a.assay_date DESC LIMIT 1;
        IF FOUND THEN
            v_lim := (v_st->>'splitting_limit_pct')::numeric;
            -- 逐元素比,取最大差
            SELECT max(abs(x.content_pct - y.content_pct)) INTO v_maxdiff
              FROM assay_result_metals x JOIN assay_result_metals y
                ON y.metal = x.metal AND y.assay_result_id = v_other.id
             WHERE x.assay_result_id = p_assay_result_id;
            IF v_maxdiff IS NOT NULL AND v_maxdiff > 0 THEN
                IF v_lim IS NULL THEN
                    RAISE EXCEPTION 'RESULTS_IN_DISPUTE|%|%|%', v_assay.code, v_other.code, v_maxdiff
                      USING HINT = '两方的化验结果不一致,而这份合同没有声明容差 —— 要么在合同里写明容差,要么记录一份仲裁结果并按它结算;系统不会替你选哪一方的数字是钱';
                ELSIF v_maxdiff > v_lim THEN
                    RAISE EXCEPTION 'RESULTS_EXCEED_SPLITTING_LIMIT|%|%|%|%', v_assay.code, v_other.code, v_maxdiff, v_lim
                      USING HINT = '两方结果的差距超过了合同声明的容差 —— 按合同该送第三方复检,并用仲裁结果结算';
                END IF;
            END IF;
        END IF;
    END IF;

    -- ── 重量基准:换算,或按名拒 ──────────────────────────────────────────
    v_basis := v_st->>'sale_weight_basis';
    v_gross := v_batch.quantity;
    v_moist := v_assay.moisture_pct;
    IF v_assay.weight_basis <> v_basis AND v_moist IS NULL THEN
        RAISE EXCEPTION 'SETTLEMENT_MOISTURE_NOT_STATED|%', v_assay.code
          USING HINT = '化验按一种基准报、合同按另一种结算,换算要用水分 —— 而这份化验没有水分,所以算不了';
    END IF;
    v_swt := CASE WHEN v_basis = 'as_received' THEN v_gross
                  ELSE round(v_gross * (1 - COALESCE(v_moist, 0) / 100.0), 4) END;

    -- ── 逐金属:含量 → 应付量 → 计价期均价 → 金额;并扣精炼费 ────────────
    FOR v_metal, v_content IN
        SELECT m.metal, m.content_pct FROM assay_result_metals m
         WHERE m.assay_result_id = p_assay_result_id ORDER BY m.metal
    LOOP
        -- 把含量换算到【结算基准】上。含金属因此是不变量 —— 见抬头。
        v_content_s := CASE
            WHEN v_assay.weight_basis = v_basis THEN v_content
            WHEN v_assay.weight_basis = 'dry' AND v_basis = 'as_received'
                THEN v_content * (1 - v_moist / 100.0)
            ELSE v_content / (1 - v_moist / 100.0) END;
        v_contained := round(v_swt * v_content_s / 100.0, 4);

        SELECT (e->>'payable_pct')::numeric INTO v_payable
          FROM jsonb_array_elements(COALESCE(v_pricing, '[]'::jsonb)) e
         WHERE e->>'metal' = v_metal;
        IF v_payable IS NULL THEN
            RAISE EXCEPTION 'SETTLEMENT_PAYABLE_NOT_STATED|%', v_metal
              USING HINT = '计价系数是一条合同条款(PRICE-1 的 contract_pricing_terms)—— 没有它就不知道买方按含量的多大比例付钱';
        END IF;
        v_pay_kg := round(v_contained * v_payable / 100.0, 4);

        -- 计价期均价 —— **调 PRICE-1 那一支,不另写一份**(两份实现会悄悄分开)
        SELECT e->>'base_event', (e->>'qp_months')::int, e->>'index_code'
          INTO v_pt_event, v_pt_months, v_pt_index
          FROM jsonb_array_elements(v_pricing) e WHERE e->>'metal' = v_metal;
        -- 【卖方向今天只记得下"化验完成"这一个事件日期】发货日与到货日在这一侧
        -- 还没有落点,所以按它们定基准月的合同**按名拒**,而不是拿一个别的日期顶替。
        v_base_date := CASE WHEN v_pt_event = 'assay_complete' THEN v_assay.assay_date END;
        IF v_base_date IS NULL THEN
            RAISE EXCEPTION 'SETTLEMENT_BASE_EVENT_DATE_UNKNOWN|%', COALESCE(v_pt_event, '(none)')
              USING HINT = '卖方向今天记得下来的事件日期只有【化验完成】—— 发货日与到货日还没有落点,所以按它们定基准月的合同结算不了';
        END IF;
        SELECT qp.qp_from, qp.qp_to INTO v_qp FROM quotational_period(v_base_date, v_pt_months) qp;
        v_price := (index_period_average(v_pt_index, v_metal, v_qp.qp_from, v_qp.qp_to)
                    ->>'avg_usd_per_tonne')::numeric;
        v_mv := v_mv + round(v_pay_kg / 1000.0 * v_price, 2);

        -- 精炼费:按【含金属】吨数 —— 所以它**不随基准变**
        v_rc := 0;
        IF v_st->>'refining_charge_basis' = 'per_metal' THEN
            SELECT (e->>'usd_per_tonne_of_metal')::numeric INTO v_rc
              FROM jsonb_array_elements(COALESCE(v_st->'refining_charges', '[]'::jsonb)) e
             WHERE e->>'metal' = v_metal;
            IF v_rc IS NULL THEN
                RAISE EXCEPTION 'REFINING_CHARGE_NOT_FILED|%|%', v_ccode, v_metal
                  USING HINT = '这份合同声明了按金属收精炼费,却没有填这一种金属的费率 —— 【声明了有】与【填了多少】是两件事,而只有后者算得出钱';
            END IF;
            v_rcs := v_rcs + round(v_contained / 1000.0 * v_rc, 2);
        END IF;

        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal, 'content_pct_assay', v_content,
            'content_pct_settlement', round(v_content_s, 6),
            'contained_kg', v_contained, 'payable_pct', v_payable,
            'payable_kg', v_pay_kg, 'price_usd_per_tonne', v_price,
            'qp_from', v_qp.qp_from, 'qp_to', v_qp.qp_to,
            'refining_charge_usd_per_tonne_of_metal', v_rc);
    END LOOP;

    -- ── 惩罚:按【结算重量】吨数 —— 所以它**随基准变** ────────────────────
    IF v_st->>'penalty_basis' = 'per_element' THEN
        IF COALESCE(jsonb_array_length(v_st->'penalty_elements'), 0) = 0 THEN
            RAISE EXCEPTION 'PENALTY_ELEMENTS_NOT_FILED|%', v_ccode
              USING HINT = '这份合同声明了按元素罚,却一条惩罚条款都没有填 —— 【声明了有】与【填了哪些】是两件事';
        END IF;
        FOR v_el IN SELECT e FROM jsonb_array_elements(v_st->'penalty_elements') e LOOP
            v_thr  := (v_el->>'threshold_pct')::numeric;
            v_rate := (v_el->>'usd_per_tonne_per_pct_over')::numeric;
            SELECT m.content_pct INTO v_content FROM assay_result_metals m
             WHERE m.assay_result_id = p_assay_result_id AND m.metal = v_el->>'substance';
            IF v_content IS NULL THEN CONTINUE; END IF;   -- 这份化验没测这个元素
            v_content_s := CASE
                WHEN v_assay.weight_basis = v_basis THEN v_content
                WHEN v_assay.weight_basis = 'dry' AND v_basis = 'as_received'
                    THEN v_content * (1 - v_moist / 100.0)
                ELSE v_content / (1 - v_moist / 100.0) END;
            v_over := v_content_s - v_thr;
            IF v_over > 0 THEN
                v_pen := v_pen + round(v_swt / 1000.0 * v_over * v_rate, 2);
                v_pens := v_pens || jsonb_build_object(
                    'substance', v_el->>'substance', 'threshold_pct', v_thr,
                    'content_pct_settlement', round(v_content_s, 6),
                    'pct_over', round(v_over, 6), 'rate', v_rate);
            END IF;
        END LOOP;
    END IF;

    v_amt := round(v_mv - v_rcs - v_pen, 2);
    RETURN jsonb_build_object(
        'sales_order_id', p_sales_order_id, 'output_batch_id', p_output_batch_id,
        'assay_result_id', p_assay_result_id, 'assay_code', v_assay.code,
        'settling_party_used', v_assay.result_party,
        'weight_basis_used', v_basis,
        'assay_weight_basis', v_assay.weight_basis,
        'gross_weight_kg', v_gross, 'moisture_pct', v_moist,
        'settlement_weight_kg', v_swt,
        'metal_value_usd', v_mv, 'refining_charge_usd', v_rcs,
        'penalty_usd', v_pen, 'amount_usd', v_amt,
        'breakdown', jsonb_build_object('metals', v_lines, 'penalties', v_pens),
        'terms_snapshot', v_st);
END
$function$;

-- ═══ 8. 把一次结算记下来(definer,自己先问权限)══════════════════════
CREATE OR REPLACE FUNCTION public.record_sale_settlement(p_sales_order_id uuid, p_output_batch_id uuid, p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- SETTLE-1:把一次结算**记下来**。算术不在这里 —— 它在 sale_settlement_compute。
--
-- ★【一处实现,两个调用者】★ 预览与落库读**同一段算术**。本仓库为
--   "两份实现在写下来那天一致、之后悄悄分开"付过四次账(AGENTS.md 的预览规则)。
--
-- ★【它是 SECURITY DEFINER,所以它【自己】问一次权限】★
--   sales_settlements 没有 INSERT 策略(刻意的:检查与写入必须同一笔事务,
--   否则分两步之间那道缝足够让一份不合口径的结算先被写下来)。
--   而"一支 definer 函数没有权限检查"是本仓库点名过的陷阱 —— 所以下面第一件事
--   就是按名问一次,而不是靠调用它的人记得先问。
--
-- ★【它【不过账】】★ 一分钱都不进总账。理由两条,各自独立:
--   ① 会计政策 5.7 自己标着 NOT BUILT;② PRICE-1 声明过断点,两阶段开票还不存在。
DECLARE
    v_r  jsonb;
    v_id uuid;
BEGIN
    IF NOT has_permission('module.customers.edit'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.customers.edit'
          USING HINT = '记录一次销售结算要有客户模块的编辑权限 —— 这不是数据缺失,是权限';
    END IF;

    -- 算(所有拒绝都在那一支里,而它们与写入在同一笔事务)
    v_r := sale_settlement_compute(p_sales_order_id, p_output_batch_id, p_assay_result_id);

    INSERT INTO sales_settlements (
        sales_order_id, output_batch_id, assay_result_id,
        settling_party_used, weight_basis_used,
        gross_weight_kg, moisture_pct, settlement_weight_kg,
        metal_value_usd, refining_charge_usd, penalty_usd, amount_usd,
        breakdown, terms_snapshot, computed_by)
    VALUES (
        p_sales_order_id, p_output_batch_id, p_assay_result_id,
        v_r->>'settling_party_used', v_r->>'weight_basis_used',
        (v_r->>'gross_weight_kg')::numeric,
        (v_r->>'moisture_pct')::numeric,
        (v_r->>'settlement_weight_kg')::numeric,
        (v_r->>'metal_value_usd')::numeric,
        (v_r->>'refining_charge_usd')::numeric,
        (v_r->>'penalty_usd')::numeric,
        (v_r->>'amount_usd')::numeric,
        v_r->'breakdown', v_r->'terms_snapshot', auth.uid())
    RETURNING id INTO v_id;

    RETURN v_r || jsonb_build_object('settlement_id', v_id, 'posted_to_ledger', false);
END
$function$;

COMMENT ON FUNCTION public.record_sale_settlement(uuid, uuid, uuid) IS
    'SETTLE-1:把一次销售结算**记下来** —— **它不过账**(返回值里那句 posted_to_ledger=false 是刻意印出来的)。算术在 sale_settlement_compute:**一处实现,两个调用者**,预览与落库读同一段算术(本仓库为「两份实现悄悄分开」付过四次账)。★**它是 SECURITY DEFINER,所以它自己先按名问一次权限**★ —— sales_settlements 没有 INSERT 策略(刻意的:检查与写入必须同一笔事务),而「definer 函数没有权限检查」是本仓库点名过的陷阱。★**为什么不过账**★:① 会计政策 5.7 自己标着 NOT BUILT(差额科目已裁定、过账路径没有);② PRICE-1 声明过断点,两阶段开票还不存在,**没有开票就没有东西喂给过账路**。';

COMMIT;
