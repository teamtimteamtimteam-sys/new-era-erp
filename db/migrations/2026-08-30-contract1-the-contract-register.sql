-- CONTRACT-1:合同登记簿 + 卖方已承诺条款 + 保险 + 目标品位与公差。
--
-- ★★【一张采购单不是一份合同 —— 这一刀补的就是那个缺掉的概念】★★
--   此前本仓库只有【单据】(purchase_orders / sales_orders / quotes)与
--   【不挂对手方、没有期限的可复用条款集】(pricing_formulas / payment_term_templates)。
--   **"合同"这个东西一张表都没有**,而后三件(卖方条款、保险、目标品位)
--   全都是【合同条款】—— 它们该待在合同上,所以合成一刀。
--
-- ★【它凭什么不是一个文件柜】★(Tim 2026-08-29 裁定 A1)
--   purchase_orders 与 sales_orders 各加一列 contract_id,
--   而 link_document_to_contract 有两条拒绝:对手方对不上、合同不是 active。
--   **两条都是【不一致】不是【政策】** —— AGENTS.md 给
--   ALLOC_CURRENCY_MISMATCH 与 ALLOC_EXCEEDS 划过这条线。
--   **刻意不拒的那一条**:单据日期落在合同期之外不拒(回填正当,而
--   "能不能背靠未生效的合同下单"没有人裁过)。
--   **而覆盖率必须被说出来**:没有任何东西强制一张单据挂合同,所以
--   "没有合同被违反"很可能只是"没有人挂过东西" —— contract_coverage 给出分母。
--
-- ★【6.2 的清点:本刀【只加不删】,而依赖仍然先数了一遍】★
--   动的是两处 ADD COLUMN(purchase_orders.contract_id / sales_orders.contract_id),
--   **没有任何 DROP 或 RENAME**。清点结果:
--     · purchase_orders **是遮蔽表**(有 purchase_orders_masked + 列授权)——
--       所以按 WO-1a 那一课,ADD COLUMN / GRANT / _masked **三件事都在本迁移里**。
--       (KPI-1 为漏掉后两件付过一次账,窗口 4 小时 44 分。)
--     · sales_orders 没有 _masked 视图,ADD + GRANT 两件。
--     · 依赖这两张表的视图共 8 个(deleted_records / grn_discrepancies /
--       operations_now / purchase_orders_masked / container_overview / quote_status
--       等)—— **加列不会破坏它们中的任何一个**(只有删列/改名会),
--       但仍然先数出来再动手,那是本刀的规矩。
--
-- 【顺序】contracts 必须先于两处 ADD COLUMN(外键指向它);
--   contract_document_terms 必须后于两张单据表拿到列;函数与视图最后。

BEGIN;

-- ═══ 1. 合同本体 ═══════════════════════════════════════════════════════
-- db/tables/contracts.sql
-- CONTRACT-1:合同登记簿 —— **一份合同,不是一张单据。**
--
-- ★【一张采购单【不是】一份合同】★
--   采购单是【在一份关系之下开出来的一张单据】;长期供货协议才是那份关系。
--   本仓库此前只有单据(purchase_orders / sales_orders / quotes)与
--   【可复用的条款集】(pricing_formulas / payment_term_templates)——
--   而后两者不挂在任何对手方身上,也没有期限。**合同这个概念今天不存在。**
--
-- ★★【它凭什么不是一个文件柜】★★(Tim 2026-08-29 裁定 A1)
--   一份没有任何东西指得着的登记簿就是一个带外键的文件柜。所以本刀给
--   purchase_orders 与 sales_orders 各加一列 contract_id,并且**有两条拒绝**:
--     · 对手方对不上(合同是这家、单据是那家)—— CONTRACT_COUNTERPARTY_MISMATCH
--     · 合同不是 active —— CONTRACT_NOT_ACTIVE
--   **两条都是【不一致】,不是【政策】** —— 这正是 AGENTS.md 给
--   ALLOC_CURRENCY_MISMATCH(不一致,该拒)与 ALLOC_EXCEEDS(政策,要先问对不对)
--   划的那条线。一个人不可能"故意"把 A 家的单挂到 B 家的合同上。
--
--   ★【刻意【不】拒的那一条,写出来免得被当成遗漏】★
--   **单据日期落在合同期之外,本刀不拒。** 回填/补录一张早于合同生效日的单据
--   是正当操作,而"能不能背靠一份还没生效的合同下单"是一个**没有人裁过**的问题。
--   没有裁定就按名拒,买到的是绕过它的办法,不是控制。
--
--   ★【而【覆盖率】必须被说出来,否则这道闸会撒谎】★(A1 的后半)
--   没有任何东西【强制】一张单据挂上合同(现货采购本来就没有合同)。
--   于是"没有合同被违反"很可能只意味着"没有人挂过任何东西"。
--   所以屏幕上必须同时给出【挂了几张 / 一共几张】—— 见 /contracts 那一页的
--   coverage 那一段。**一个具名的缺席,不是一张干净的体检表。**
--
-- ★【一张表同时装买方与卖方合同,而它【不是】一方两身那个结构】★(A4)
--   一行【恰好】属于一边(num_nonnulls CHECK),与 counterparty_contacts 同一个惯用法。
--   **PARTY-1 那句警告原样搬过来:它不把任何客户与任何供应商连起来。**
--   同一家公司同时是供应商与客户时,它会有【两份】合同 —— 而那是对的,
--   因为那两份协议本来就是两份。
--
-- ★★【条款是【兄弟】,不是本表上越加越多的列】★★(A5 —— 给第 4 刀留的门)
--   目标品位(contract_grade_specs)、保险义务(contract_insurance_obligations)、
--   数量承诺(contract_volume_commitments)各是一张挂在 contract_id 上的子表。
--   **第 4 刀的指数挂钩定价应当落成【第四个兄弟】** ——
--   建议命名 `contract_pricing_terms`,同样以 contract_id 为键。
--   **本刀刻意【不】预建那张空表**:一张没有写入方的空表,正是 PARTY-1 上一刀
--   点名过的"写给谁都不看的表单"。
--   **也刻意不把定价的列加在本表上"留着以后用"** —— 那正是第 4 刀要迁走的形状。
--   这段注释就是那个交接点,它本身就是本刀的交付物之一。
--

CREATE SEQUENCE public.contract_code_seq;

CREATE TABLE public.contracts (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,   -- 'CON-YYYY-NNNN',触发器取号
    -- 【恰好属于一边】两个都填或都不填,都是"这份合同是跟谁签的"没有答案。
    customer_id    uuid REFERENCES public.customers (id) ON DELETE RESTRICT,
    supplier_id    uuid REFERENCES public.suppliers (id) ON DELETE RESTRICT,
    -- 买/卖:由归属那一侧推导,存下来是为了让筛选与阅读都不必再推一次。
    -- 【它是派生的,所以不可写】—— 两处都能写就是两个真源。
    side           text GENERATED ALWAYS AS
                   (CASE WHEN customer_id IS NOT NULL THEN 'sell' ELSE 'buy' END) STORED,
    kind           text NOT NULL CHECK (kind IN ('supply','offtake','framework','service','other')),
    title          text NOT NULL CHECK (btrim(title) <> ''),
    -- 【期限】effective_to 可空 = 无固定期限(常见于框架协议),不是"忘了填"。
    effective_from date NOT NULL,
    effective_to   date,
    signed_on      date,
    status         text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','active','suspended','expired','terminated')),
    -- ── 合同层的商务条款(单据挂上来时会被【抄走】,见 contract_document_terms)──
    -- 【全部可空】一份框架协议可以不定币种、不定贸易术语;硬要必填就是逼人编。
    currency       text REFERENCES public.currencies (code),
    incoterm       text,
    payment_terms_days integer CHECK (payment_terms_days IS NULL
                                      OR (payment_terms_days >= 0 AND payment_terms_days <= 365)),
    document_ref   text,
    notes          text,
    deleted_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid(),
    CONSTRAINT contracts_exactly_one_counterparty
        CHECK (num_nonnulls(customer_id, supplier_id) = 1),
    CONSTRAINT contracts_period_order
        CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX idx_contracts_customer ON public.contracts (customer_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_contracts_supplier ON public.contracts (supplier_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_contracts_status ON public.contracts (status) WHERE deleted_at IS NULL;

-- 取号:与 customers / suppliers 同一形状
CREATE OR REPLACE FUNCTION public.assign_contract_code()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'CON-' || to_char(COALESCE(NEW.effective_from, CURRENT_DATE), 'YYYY')
                    || '-' || lpad(nextval('public.contract_code_seq')::text, 4, '0');
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_contracts_code
    BEFORE INSERT ON public.contracts
    FOR EACH ROW EXECUTE FUNCTION public.assign_contract_code();

CREATE TRIGGER trg_contracts_updated_at
    BEFORE UPDATE ON public.contracts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.contracts ENABLE ROW LEVEL SECURITY;

-- 【读写权限跟着【归属那一侧】走】买方合同要 suppliers 的门,卖方合同要 customers 的门。
-- 与 counterparty_contacts 逐字同一条:一个只做采购的人不该读得到销售合同的条款。
CREATE POLICY "contracts select by owner permission"
    ON public.contracts AS PERMISSIVE FOR SELECT TO authenticated
    USING ((customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
        OR (supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)));
CREATE POLICY "contracts insert by owner permission"
    ON public.contracts AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK ((customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
             OR (supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)));
CREATE POLICY "contracts update by owner permission"
    ON public.contracts AS PERMISSIVE FOR UPDATE TO authenticated
    USING ((customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
        OR (supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))
    WITH CHECK ((customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
             OR (supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)));

COMMENT ON TABLE public.contracts IS
    'CONTRACT-1:合同登记簿 —— **一份合同,不是一张单据**。采购单是在一份关系之下开出来的单据,长期供货协议才是那份关系;此前本仓库只有单据与不挂对手方、没有期限的可复用条款集。★**它凭什么不是文件柜**★:purchase_orders / sales_orders 各带一列 contract_id,而 link_document_to_contract 有两条拒绝 —— 对手方对不上、合同不是 active。**两条都是【不一致】不是【政策】**(AGENTS.md 给 ALLOC_CURRENCY_MISMATCH 与 ALLOC_EXCEEDS 划的那条线)。★**刻意不拒的那一条**★:单据日期落在合同期之外【不拒】—— 回填是正当操作,而"能不能背靠一份未生效的合同下单"没有人裁过,没裁定就按名拒买到的是绕过它的办法。★**而覆盖率必须被说出来**★:没有任何东西强制一张单据挂合同(现货采购本来就没有),所以"没有合同被违反"很可能只是"没有人挂过东西" —— /contracts 那一页给出【挂了几张 / 一共几张】。★**它不是一方两身那个结构**★(原样搬自 PARTY-1):一行恰好属于一边,**它不把任何客户与任何供应商连起来**;同一家公司同时在两侧时会有两份合同,而那是对的,因为那两份协议本来就是两份。★**条款是兄弟,不是本表上越加越多的列**★:品位规格 / 保险义务 / 数量承诺各是一张挂 contract_id 的子表,**第 4 刀的指数挂钩定价应当落成第四个兄弟(建议 `contract_pricing_terms`,同样以 contract_id 为键)** —— 本刀刻意不预建那张空表(没有写入方的空表是 PARTY-1 点名过的"写给谁都不看的表单"),也刻意不把定价的列加在本表上"留着以后用"(那正是第 4 刀要迁走的形状)。';

COMMENT ON COLUMN public.contracts.side IS
    'CONTRACT-1:买还是卖 —— **派生列,不可写**。由归属哪一侧推导(有客户就是 sell,有供应商就是 buy);存下来只是为了筛选与阅读不必再推一次。两处都能写就是两个真源(与 suppliers.supplies_goods 同一条)。';

COMMENT ON COLUMN public.contracts.effective_to IS
    'CONTRACT-1:**可空 = 没有固定期限**(框架协议常常如此),不是"忘了填"。硬要它必填,就是逼人编一个日期出来 —— 而那个日期后来会被当成真的。';

-- ═══ 2. 条款:三个【兄弟】子表(第 4 刀的定价是第四个)══════════════════
-- db/tables/contract_grade_specs.sql
-- CONTRACT-1:目标品位与公差 —— **一条合同条款**,不是物料主数据上的一个字段。
--
-- 【为什么它挂在合同上】(proc-reality 的 G11 被 U8 挡着,而 U8 写的是
--  「第一份带规格的供货合同」)—— **本刀建的正是那样一份合同**,所以 G11 的
--  前置条件由这一刀满足,而不是另外再裁一次。
--  同一种物料在两份合同下可以有两套规格,而 materials.spec 是一段自由文本、
--  一种物料只有一份 —— 它表达不了"这一份合同要求的是什么"。
--
-- ★★【min / max,而不是 target ± tolerance】★★(Tim 2026-08-29 裁定 A2)
--   真实合同写的多半是**单边**的:「Ni ≥ 18%」「Cu ≤ 0.5%」。
--   而 target±tolerance 是 min/max 的一个对称特例 —— 用 min/max 表达得了,
--   反过来不行。**两种都存就是同一个事实两个写法**,而两个写法迟早会各说各话。
--   两个界至少要有一个(下面那条 CHECK),因为**一条两边都不设限的"规格"
--   什么也没规定**。
--
-- ★★【它【报告】违反,不【拒绝】交货 —— 而理由是具体的,不是胆小】★★(A2)
--   化验结果回来的时候,**货已经在场上了**。而这套系统里**没有"质量暂扣"这个状态**
--   (全库 0 张相关表;那是阶段 6 的 G29)。
--   **拒绝一样自己没有地方安放的东西,不是一道控制** —— 它只是把一批物理上
--   已经躺在仓库里的货的单据流程堵住。所以本刀把违反做成一个【看得见的、具名的发现】
--   (contract_grade_breaches 视图),而不是一道闸。
--   **升成闸的触发条件已经排进队列:G29 的质量暂扣落地那一天。**
--
-- 【它拿什么去比】assay_result_metals.content_pct(0–100 的 numeric,
--   metal 外键指向 substances)—— 那是这套系统里**真正量出来的**含量,
--   而化验挂在 inbound_batch 或 output_batch 上(恰好一个)。
--   所以"这批货有没有达到这份合同的规格"是一个答得出来的问题。
--

CREATE TABLE public.contract_grade_specs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 【物料可空】一份合同可以只规定"镍不低于 18%",不指定具体料号。
    material_id uuid REFERENCES public.materials (id) ON DELETE RESTRICT,
    -- 比的是哪一种元素 —— 与 assay_result_metals.metal 同一个字典
    metal       text NOT NULL REFERENCES public.substances (code),
    min_pct     numeric CHECK (min_pct IS NULL OR (min_pct >= 0 AND min_pct <= 100)),
    max_pct     numeric CHECK (max_pct IS NULL OR (max_pct >= 0 AND max_pct <= 100)),
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid(),
    -- 同一份合同、同一种物料、同一种元素只规定一次;否则"哪一条说了算"
    -- 会变成一次按写入时刻的破平局 —— AGING-1 栽过的那个坑。
    UNIQUE (contract_id, material_id, metal),
    -- ★ 至少一个界:两边都不设限的"规格"什么也没规定
    CONSTRAINT contract_grade_specs_needs_a_bound
        CHECK (min_pct IS NOT NULL OR max_pct IS NOT NULL),
    -- 下界不能高于上界 —— 否则这条规格【永远】不可能被满足,
    -- 而它会安静地把每一批货都报成违反
    CONSTRAINT contract_grade_specs_bounds_ordered
        CHECK (min_pct IS NULL OR max_pct IS NULL OR min_pct <= max_pct)
);

CREATE INDEX idx_contract_grade_specs_contract ON public.contract_grade_specs (contract_id);

ALTER TABLE public.contract_grade_specs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract grade specs select by owner permission"
    ON public.contract_grade_specs AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract grade specs write by owner permission"
    ON public.contract_grade_specs AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_grade_specs IS
    'CONTRACT-1:目标品位与公差 —— **一条合同条款**,不是物料主数据上的字段(同一种物料在两份合同下可以有两套规格,而 materials.spec 是自由文本且一种物料只有一份)。★**min/max,不是 target ± tolerance**★:真实合同多半是单边的(Ni ≥ 18%、Cu ≤ 0.5%),而 target±tolerance 是 min/max 的对称特例 —— 用 min/max 表达得了,反过来不行,**两种都存就是同一个事实两个写法**。至少要有一个界,因为两边都不设限的规格什么也没规定。★★**它报告违反,不拒绝交货,而理由是具体的**★★:化验回来时**货已经在场上**,而这套系统里没有"质量暂扣"这个状态(阶段 6 的 G29)—— **拒绝一样自己没有地方安放的东西不是控制**,只是把物理上已在仓库的货的单据流程堵住。违反做成具名发现(contract_grade_breaches),升成闸的触发条件是 G29 落地。它拿 assay_result_metals.content_pct 去比 —— 那是这套系统里真正量出来的含量。**G11 此前被 U8 挡着,而 U8 的触发条件写的正是「第一份带规格的供货合同」—— 本刀建的就是那个。**';

COMMENT ON COLUMN public.contract_grade_specs.max_pct IS
    'CONTRACT-1:上界。**与 min_pct 至少有一个**。杂质条款(Cu ≤ 0.5%)只有上界、品位条款(Ni ≥ 18%)只有下界,两者都是常态 —— 逼两个都填就是逼人编一个界出来,而编出来的界会被当成谈成的条款。';

-- db/tables/contract_insurance_obligations.sql
-- CONTRACT-1:合同里那条【谁来投保、保到多少】的义务。
--
-- ★★【这【不是】保险登记簿的第二个家 —— 它们是两件事,而判据是它们能各自为真】★★
--   (Tim 2026-08-29 裁定 A3)
--
--   · **我们持有的保单**:一份有【到期日】的东西,由既有那套机制管着 ——
--     `certificate_types`(RUNTIME CONFIG:加一种证书是在界面上加一行,不是跑迁移)
--     + `company_compliance`(我们自己那一侧,已经有 cert_no / issuing_body /
--     scope / valid_from / valid_until / document_path,而且它的表注写着
--     "第一张真执照进来不需要任何 schema 变更")。
--     **它已经有两个消费方**:`operations_now` 的看板臂与 `supplier_receiving_blocked`
--     的收货闸。给保险再造一套到期机制,就是把这两样又写一遍。
--
--   · **合同里那条义务**:一件【没有自己的到期日】的事。它约束的是【对手方】,
--     而它被违反的方式是**一份保单不存在**,不是一份保单过期。
--
--   两者能各自为真:我们可以持有一份保单而没有任何合同要求它;
--   一份合同可以要求投保而我们(或对方)一张保单都没有。
--   **所以它们是两个事实,不是一个事实的两个家。**
--
-- ★【本刀【刻意不建】那条连接:哪一份保单满足哪一条义务】★
--   "policy P 满不满足 contract C 的这条义务"是一次**判断**(险种对不对得上、
--   保额够不够、保障区间盖不盖得住、被保险人是不是对的那一方)——
--   **没有人裁过它**。而一条猜出来的自动连接会把一份【没有保障的合同报成已保障】,
--   那比不连坏得多。见 docs/known-issues.md 里那一条,附上它需要什么才答得了。
--

CREATE TABLE public.contract_insurance_obligations (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id    uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 【谁投保】这份义务落在哪一方身上 —— 合同里最常被记错的一格。
    insured_by     text NOT NULL CHECK (insured_by IN ('us','counterparty')),
    -- 险种。**不做成枚举**:货运险/产品责任/环境责任……各家合同的叫法不一样,
    -- 一个猜出来的枚举会逼人把真实险种塞进最近的那一格(与 role 那一列同一条)。
    cover_type     text NOT NULL CHECK (btrim(cover_type) <> ''),
    -- 最低保额。**可空** —— 有些条款只写"须投保",不写金额;
    -- 填了金额就必须有币种(下面那条 CHECK),否则那个数会被读错。
    min_amount     numeric CHECK (min_amount IS NULL OR min_amount >= 0),
    currency       text REFERENCES public.currencies (code),
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid(),
    -- 【一个没有单位的金额不是金额,是一个会被读错的数】—— 与 review_goals 的
    -- unit_required、payment_term_templates 的币种是同一条(FIN-29)。
    CONSTRAINT contract_insurance_amount_needs_currency
        CHECK (min_amount IS NULL OR currency IS NOT NULL)
);

CREATE INDEX idx_contract_insurance_contract
    ON public.contract_insurance_obligations (contract_id);

ALTER TABLE public.contract_insurance_obligations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract insurance select by owner permission"
    ON public.contract_insurance_obligations AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract insurance write by owner permission"
    ON public.contract_insurance_obligations AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_insurance_obligations IS
    'CONTRACT-1:合同里那条「谁来投保、保到多少」的义务。★★**它不是保险登记簿的第二个家 —— 两件事,判据是它们能各自为真**★★(Tim 2026-08-29):**我们持有的保单**是一件有到期日的东西,由既有机制管着(certificate_types 是 RUNTIME CONFIG,加一种证书是界面上加一行;company_compliance 已有 cert_no/issuing_body/scope/valid_from/valid_until/document_path,且已经有两个消费方 —— operations_now 的看板臂与 supplier_receiving_blocked 的收货闸)。**给保险再造一套到期机制,就是把那两样又写一遍。** 而**合同里那条义务没有自己的到期日**,它约束对手方,被违反的方式是**一份保单不存在**而不是一份保单过期。两者能各自为真:可以持有保单而无合同要求,也可以有要求而一张保单都没有。★**本刀刻意不建那条连接(哪份保单满足哪条义务)**★ —— 那是一次判断(险种、保额、保障区间、被保险人),没有人裁过,而一条猜出来的自动连接会把一份没有保障的合同报成已保障,比不连坏得多;记在 known-issues,附上它需要什么才答得了。';

-- db/tables/contract_volume_commitments.sql
-- CONTRACT-1:卖方已承诺的量 —— 「每月不少于 200 吨」这一类条款。
--
-- 【为什么这一张与品位、保险并列而不是塞在合同行上】(A5)
--   它们都是【条款】,而条款天然是一串:一份合同可以承诺两种物料、
--   可以按月也可以按季。塞进合同那一行就得覆盖,而覆盖会让"当初承诺的是什么"消失。
--
-- ★【承诺的是【谁】—— 这一列不是装饰】★
--   在一份采购合同里,承诺供货的是【对方】;在一份销售合同里,承诺供货的是【我们】。
--   两者的下一步完全不同(前者是"催他交",后者是"我们排产"),
--   而只存一个数字的实现说不出是哪一种。
--
-- 【period 是【口径】,不是日历】'month'/'quarter'/'year'/'total' ——
--   'total' 表示"整个合同期内合计",那是框架协议的常见写法。
--   **本刀不算达成率**:算达成率要先回答"哪些单据算进这份承诺"
--   (下单算还是收货算?跨月的一船算哪个月?)—— 没有人裁过,
--   而一个算得出数、口径没人定过的达成率,比没有更坏。
--   记在 known-issues,带触发条件。
--

CREATE TABLE public.contract_volume_commitments (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 谁承诺的 —— 见抬头
    committed_by_party text NOT NULL CHECK (committed_by_party IN ('us','counterparty')),
    material_id  uuid REFERENCES public.materials (id) ON DELETE RESTRICT,
    quantity     numeric NOT NULL CHECK (quantity > 0),
    unit         text NOT NULL CHECK (btrim(unit) <> ''),
    period       text NOT NULL CHECK (period IN ('month','quarter','year','total')),
    -- 承诺是"不少于"还是"不超过" —— 供货承诺与产能上限都是真实条款
    direction    text NOT NULL DEFAULT 'min' CHECK (direction IN ('min','max')),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid()
);

CREATE INDEX idx_contract_volume_contract ON public.contract_volume_commitments (contract_id);

ALTER TABLE public.contract_volume_commitments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract volume select by owner permission"
    ON public.contract_volume_commitments AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract volume write by owner permission"
    ON public.contract_volume_commitments AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_volume_commitments IS
    'CONTRACT-1:卖方已承诺的量(「每月不少于 200 吨」这一类)。与品位、保险并列是因为它们都是【条款】,而条款天然是一串 —— 塞进合同那一行就得覆盖,覆盖会让"当初承诺的是什么"消失。`committed_by_party` 不是装饰:采购合同里承诺供货的是对方,销售合同里是我们,而两者的下一步完全不同(催他交 vs 我们排产),只存一个数字的实现说不出是哪一种。★**本刀不算达成率**★:那要先回答"哪些单据算进这份承诺"(下单算还是收货算?跨月的一船算哪个月?)—— 没有人裁过,而**一个算得出数、口径没人定过的达成率比没有更坏**;记在 known-issues,带触发条件。';


-- ═══ 3. 两张单据表挂得上合同 —— ADD / GRANT / _masked,三件一起 ════════════
-- 【为什么三件一起】purchase_orders 是遮蔽表,而列清单 SELECT 授权
-- **不会自动扩展到后加的列**(表级 INSERT/UPDATE 会,SELECT 不会)。
-- 漏掉 GRANT 或 _masked,就会造出一个"写得进、读不出"的列 ——
-- FIN-6 就是这么让 /finance/processing-costs 从上线那天起就是空的,而所有闸都是绿的。
ALTER TABLE public.purchase_orders
    ADD COLUMN contract_id uuid REFERENCES public.contracts (id) ON DELETE RESTRICT;
ALTER TABLE public.sales_orders
    ADD COLUMN contract_id uuid REFERENCES public.contracts (id) ON DELETE RESTRICT;

GRANT SELECT (contract_id) ON public.purchase_orders TO authenticated;
GRANT SELECT (contract_id) ON public.sales_orders TO authenticated;

COMMENT ON COLUMN public.purchase_orders.contract_id IS
    'CONTRACT-1:这张单据挂在哪一份合同之下。**可空** —— 现货采购本来就没有合同。★**它是导航,不是条款的来源**★:条款读 contract_document_terms 那份【挂上去那一刻抄下来的】副本,顺着这一列回查合同"现在"的条款就是把抄退化成引用。';
COMMENT ON COLUMN public.sales_orders.contract_id IS
    'CONTRACT-1:这张单据挂在哪一份合同之下。**可空** —— 现货销售本来就没有合同。★**它是导航,不是条款的来源**★:条款读 contract_document_terms 那份副本。';

-- ═══ 4. 遮蔽视图跟着加列(必须与 ADD COLUMN 同一次迁移)══════════════
-- db/views/purchase_orders_masked.sql
-- 遮蔽伴生视图:purchase_orders 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:estimated_total_ccy → data.view_prices, fx_rate → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.purchasing.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

CREATE OR REPLACE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    supplier_id,
    order_date,
    expected_delivery_date,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_total_ccy
            ELSE NULL::numeric
        END AS estimated_total_ccy,
    status,
    approval_status,
    approved_at,
    approved_by,
    incoterm,
    terms_text,
    notes,
    closed_at,
    cancelled_at,
    cancel_reason,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    deleted_by,
    delete_reason,
    cancelled_by,
    -- CONTRACT-1:这张单据挂在哪一份合同之下。**新列加在末尾** ——
    -- CREATE OR REPLACE VIEW 只许末尾追加,中间插一列要 DROP + 重建。
    -- 【它必须出现在这张视图里】purchase_orders 是遮蔽表,而 colgrant 那道闸要求
    -- 它的每一列要么被列授权、要么在 _masked 里(WO-1a 那一课:ADD/GRANT/_masked
    -- 三件事要在同一次迁移里做完 —— KPI-1 为漏掉后两件付过一次账)。
    -- 【条款不从这一列读】它只是导航;条款读 contract_document_terms 那份副本。
    contract_id
   FROM purchase_orders
  WHERE has_permission('module.purchasing.view'::text);

-- ═══ 5. 挂上去那一刻抄下来的条款(FIN-27 的形状)═══════════════════════
-- db/tables/contract_document_terms.sql
-- CONTRACT-1:一张单据挂上一份合同时,**把当时在效的条款抄下来**。
--
-- ★★【抄,不是引用 —— 而这个形状本仓库已经建过一次,本刀照抄那一次】★★
--   先例是 `pricing_term_commitments`(FIN-27):它把 source_formula_id / code / name
--   **连同那一刻的实际数值**一起抄到承诺记录上,结算读那份副本。
--   同一条还出现过两次:GST-2 的税率在开票那一刻冻结、
--   PARTY-1 的 bill_to_snapshot 在开票那一刻抄下抬头。
--
--   **理由一句话:一张单据当时是按哪些条款开出去的,是一件【已经发生】的事。**
--   合同后来改了条款,不该回头改写那张单据当时依据的东西 ——
--   那不是"更新",那是改历史。
--
--   所以下面每一个来自合同的字段都是【抄过来的值】:
--   contract_code / incoterm / currency / payment_terms_days / grade_specs。
--   contract_id 只用来回答"它挂在哪一份合同上",
--   **任何读取路径都不许拿它回查条款内容** —— 一旦那么写,抄就退化成了引用,
--   而退化是静悄悄的。
--
--   ★ FIN-27 留下的下半句一并继承:
--     **引用了合同却没有留下副本的记录,要按名拒绝,
--       不许悄悄回退去读"现在的合同"。**
--     所以 contract_code 是 NOT NULL —— 一条没抄下合同编号的记录建不出来。
--
-- 【品位规格抄成 jsonb 数组,而合同那一侧是真表 —— 刻意不同】
--   与 PARTY-1 的 kpi_entries.org_codes / counterparty_contacts 同一条判断:
--   **活的主数据要引用完整性,冻住的事实要自成一体。**
--   于是"合同现在要求什么"与"这张单据当时依据什么"是两份推导,
--   而它们【本来就该在合同被改之后分开】—— 那正是抄不是引用看得见的样子。
--

CREATE TABLE public.contract_document_terms (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 【恰好挂一张单据】与 pricing_term_commitments 的两列同一形状
    purchase_order_id  uuid UNIQUE REFERENCES public.purchase_orders (id) ON DELETE CASCADE,
    sales_order_id     uuid UNIQUE REFERENCES public.sales_orders (id) ON DELETE CASCADE,
    -- ── 来源:只回答"挂在哪一份合同上",不用于回查内容 ─────────────────────
    contract_id        uuid NOT NULL REFERENCES public.contracts (id) ON DELETE RESTRICT,
    -- ── 抄过来的那一份(改合同不动这里)──────────────────────────────────
    contract_code      text NOT NULL CHECK (btrim(contract_code) <> ''),
    contract_title     text,
    incoterm           text,
    currency           text,
    payment_terms_days integer,
    -- 品位规格的快照:[{metal, min_pct, max_pct, material_id}, …]
    -- **空数组是合法的**(合同可以不规定品位),而 NULL 不是 —— 见下面那条 CHECK:
    -- "没有规格"与"没抄"必须分得开。
    grade_specs        jsonb NOT NULL DEFAULT '[]'::jsonb,
    linked_at          timestamptz NOT NULL DEFAULT now(),
    linked_by          uuid DEFAULT auth.uid(),
    CONSTRAINT contract_document_terms_exactly_one_document
        CHECK (num_nonnulls(purchase_order_id, sales_order_id) = 1),
    CONSTRAINT contract_document_terms_grade_specs_is_array
        CHECK (jsonb_typeof(grade_specs) = 'array')
);

CREATE INDEX idx_contract_document_terms_contract
    ON public.contract_document_terms (contract_id);

ALTER TABLE public.contract_document_terms ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT/UPDATE 策略】唯一写入口是 link_document_to_contract
-- (SECURITY DEFINER)—— 那两条拒绝(对手方对不上、合同不是 active)必须与
-- 抄写在【同一笔事务】里,否则可以先抄下条款再让检查失败。
CREATE POLICY "contract document terms select by owner permission"
    ON public.contract_document_terms AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));

COMMENT ON TABLE public.contract_document_terms IS
    'CONTRACT-1:一张单据挂上一份合同时,**把当时在效的条款抄下来**。★★**抄,不是引用**★★ —— 形状照抄 `pricing_term_commitments`(FIN-27:把 source_formula_id/code/name 连同那一刻的数值一起抄到承诺记录上,结算读副本);同一条还出现过两次(GST-2 的税率在开票那刻冻结、PARTY-1 的 bill_to_snapshot)。**一张单据当时按哪些条款开出去,是一件已经发生的事** —— 合同后来改了条款不该回头改写它,那不是更新,那是改历史。contract_code/incoterm/currency/payment_terms_days/grade_specs 全是抄过来的值;contract_id 只回答"挂在哪一份合同上",**任何读取路径都不许拿它回查条款内容**,一旦那么写,抄就静悄悄退化成了引用。FIN-27 的下半句一并继承:**引用了合同却没留下副本的记录要按名拒**,所以 contract_code 是 NOT NULL。品位规格抄成 jsonb 数组而合同那侧是真表 —— 刻意不同(活的主数据要引用完整性,冻住的事实要自成一体),于是"合同现在要求什么"与"这张单据当时依据什么"是两份推导,而它们本来就该在合同被改之后分开。**写入只走 link_document_to_contract**:那两条拒绝必须与抄写在同一笔事务里,否则可以先抄下条款再让检查失败。';

COMMENT ON COLUMN public.contract_document_terms.grade_specs IS
    'CONTRACT-1:抄下来的品位规格快照。**空数组合法,NULL 不合法** —— 一份合同可以不规定品位,而"没有规格"与"没抄下来"必须分得开:后者意味着这条记录是坏的,而一个 NULL 会把两者读成同一件事(与 lib/permissions.ts 让 null 与 0 分得开是同一条)。';

-- ═══ 6. 唯一的写入口 ══════════════════════════════════════════════════
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

    INSERT INTO contract_document_terms (
        purchase_order_id, sales_order_id, contract_id,
        contract_code, contract_title, incoterm, currency, payment_terms_days,
        grade_specs, linked_by)
    VALUES (
        CASE WHEN p_document_kind = 'purchase_order' THEN p_document_id END,
        CASE WHEN p_document_kind = 'sales_order'    THEN p_document_id END,
        v_con.id,
        v_con.code, v_con.title, v_con.incoterm, v_con.currency, v_con.payment_terms_days,
        v_specs, auth.uid());

    -- 单据那一行也记下它挂在哪 —— 这一列是【导航】,条款仍然读上面那份副本。
    IF p_document_kind = 'purchase_order' THEN
        UPDATE purchase_orders SET contract_id = v_con.id WHERE id = p_document_id;
    ELSE
        UPDATE sales_orders SET contract_id = v_con.id WHERE id = p_document_id;
    END IF;

    RETURN jsonb_build_object(
        'document_kind', p_document_kind, 'document_code', v_doc_code,
        'contract_code', v_con.code,
        'grade_specs_copied', jsonb_array_length(v_specs));
END;
$function$;

COMMENT ON FUNCTION public.link_document_to_contract(text, uuid, uuid) IS
'CONTRACT-1:把一张单据挂到合同上,并**当场把在效条款抄下来**。★**这支函数就是"登记簿不是文件柜"那句话的实现**★:两条拒绝 —— 对手方对不上、合同不是 active —— 而**两条都是【不一致】不是【政策】**(AGENTS.md 给 ALLOC_CURRENCY_MISMATCH 与 ALLOC_EXCEEDS 划的线):没有人会故意把 A 家的单挂到 B 家的合同上。★**刻意不拒的那一条**★:单据日期落在合同期之外【不拒】—— 回填是正当操作,而"能不能背靠未生效的合同下单"没有人裁过,没裁定就按名拒买到的是绕过它的办法。**抄写与检查在同一笔事务里**,这也是 contract_document_terms 不开 INSERT 策略的理由:分两步之间那道缝足够让一份刚被改成 terminated 的合同把条款抄出去。已经挂过按名拒,不悄悄改挂 —— 改挂等于把一张单据当初依据的条款换掉。';

-- ═══ 7. 保险 = 既有的证书机制,加一个类型 ═════════════════════════════════
-- ★【不建第二套到期机制】★(Tim 2026-08-29 裁定 A3)
--   certificate_types 是 RUNTIME CONFIG(check_mirrors 不逐行比对),
--   所以【加一种证书本来就是编辑一行,不是跑迁移】。这里插一行是因为
--   **线上不会自己长出它** —— 引导默认值只在全新安装时被种下。
--   ON CONFLICT DO NOTHING:操作员可能已经自己加过同名的一行,
--   而那一行是他的地盘,本迁移不该覆盖它。
INSERT INTO public.certificate_types (code, name_en, name_zh, disposition, warn_lead_days, sort_order, notes)
VALUES ('insurance', 'Insurance Policy', '保险单', 'warn', 60, 8,
        '默认 warn 是【默认值】不是决定:过期保单要立刻处理,但"停不停收货"是经营决定,disposition 在界面上改得动')
ON CONFLICT (code) DO NOTHING;

-- ═══ 8. 派生视图:违反与覆盖率 ════════════════════════════════════════
-- db/views/contract_grade_breaches.sql
-- CONTRACT-1:哪一批货没达到它那份合同要求的品位 —— **一个发现,不是一道闸**。
--
-- ★★【为什么是报告而不是拒绝,而理由是具体的】★★(Tim 2026-08-29 裁定 A2)
--   化验结果回来的时候,**货已经在场上了**。而这套系统里
--   **没有"质量暂扣"这个状态**(全库 0 张相关表;那是阶段 6 的 G29)。
--   **拒绝一样自己没有地方安放的东西,不是一道控制** ——
--   它只会把一批物理上已经躺在仓库里的货的单据流程堵住,
--   而货还在那儿,只是没人再说得清它的状态。
--   **升成闸的触发条件已经排队:G29 的质量暂扣落地那一天。**
--
-- ★【它比的是【单据当时抄下的那份规格】,不是合同今天的规格】★
--   来源是 contract_document_terms.grade_specs 那个快照 ——
--   一批 8 月收的货,该按 8 月那份合同判,不该按今天改过之后的合同判。
--   这与 FIN-27 的已承诺条款、GST-2 的开票冻结税率是同一条。
--
-- 【非空由构造保证:它只在【三样都在】时才出行】
--   一张挂了合同的采购单、一批挂在那张单上的入库、一份化验。
--   缺任何一样都不出行 —— 而那不是"没有违反",是"没有可比的东西"。
--   **屏幕上那句具名缺席说的就是这件事**(见 /contracts 那一页)。
--
-- 【属主权限】它 join 合同、单据、入库与化验四族,分属不同模块;
-- 谓词写进视图体(OPS-14 的补救 (a))—— 一个 invoker 视图在这里会静静少行。

CREATE VIEW public.contract_grade_breaches WITH (security_invoker = off) AS
 SELECT po.id AS purchase_order_id,
    po.code AS purchase_order_code,
    t.contract_id,
    t.contract_code,
    ib.id AS inbound_batch_id,
    ib.code AS inbound_batch_code,
    a.id AS assay_result_id,
    a.assay_date,
    m.metal,
    m.content_pct,
    (spec.value ->> 'min_pct')::numeric AS min_pct,
    (spec.value ->> 'max_pct')::numeric AS max_pct,
    -- 违反的是哪一边,说出来 —— "低于下限"与"高于上限"的下一步不同
    CASE WHEN (spec.value ->> 'min_pct') IS NOT NULL
              AND m.content_pct < (spec.value ->> 'min_pct')::numeric THEN 'below_min'
         ELSE 'above_max' END AS breach_side
   FROM contract_document_terms t
     JOIN purchase_orders po ON po.id = t.purchase_order_id
     JOIN LATERAL jsonb_array_elements(t.grade_specs) spec ON true
     JOIN inbound_batches ib ON ib.purchase_order_id = po.id AND ib.deleted_at IS NULL
     JOIN assay_results a ON a.inbound_batch_id = ib.id AND a.deleted_at IS NULL
                         AND a.superseded_by IS NULL
     JOIN assay_result_metals m ON m.assay_result_id = a.id
                               AND m.metal = spec.value ->> 'metal'
  WHERE has_permission('module.suppliers.view'::text)
    AND (((spec.value ->> 'min_pct') IS NOT NULL
          AND m.content_pct < (spec.value ->> 'min_pct')::numeric)
      OR ((spec.value ->> 'max_pct') IS NOT NULL
          AND m.content_pct > (spec.value ->> 'max_pct')::numeric));

COMMENT ON VIEW public.contract_grade_breaches IS
    'CONTRACT-1:哪一批货没达到它那份合同要求的品位 —— **一个发现,不是一道闸**(Tim 2026-08-29)。化验回来时**货已经在场上**,而这套系统里没有"质量暂扣"这个状态(阶段 6 的 G29)—— **拒绝一样自己没有地方安放的东西不是控制**,只会把物理上已在仓库的货的单据流程堵住;升成闸的触发条件是 G29 落地。★**它比的是单据当时抄下的那份规格,不是合同今天的规格**★:来源是 contract_document_terms.grade_specs 快照 —— 一批 8 月收的货该按 8 月那份合同判(与 FIN-27、GST-2 同一条)。**非空由构造保证**:只有在「挂了合同的采购单 + 挂在它上面的入库 + 一份未被取代的化验」三样都在时才出行,缺任何一样都不出行 —— 而那不是"没有违反",是"没有可比的东西",屏幕上那句具名缺席说的就是这件事。';

-- db/views/contract_coverage.sql
-- CONTRACT-1:★**多少张单据跑在合同之下,多少张没有**★ —— A1 那句"honest cost"的落地。
--
-- ★★【没有这张视图,那道闸会撒谎】★★(Tim 2026-08-29 裁定 A1)
--   本刀**没有强制**任何单据挂上合同,而且那是对的:现货采购本来就没有合同。
--   后果是覆盖率**完全是自愿的** —— 于是
--   **「没有任何合同被违反」很可能只意味着「没有人挂过任何东西」**。
--   两句话在屏幕上必须分得开,而分开它们的唯一办法就是把【分母】摆出来。
--
--   这与 PARTY-1 的重叠报告是同一条:那一份因为客户侧一个 tax_id 都没有,
--   「0 条重叠」必然为真而毫无信息,所以它带着 coverage 一起返回。
--   **一个永远为真的判词是装饰。**
--
-- 【它【不】评判覆盖率高低】没有人裁过"多少比例的采购应当在合同之下" ——
--   现货买卖是正当的商业形态,不是一个待修的缺口。所以这里只报数,不报警。

CREATE VIEW public.contract_coverage WITH (security_invoker = off) AS
 WITH po AS (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE contract_id IS NOT NULL) AS under_contract
      FROM purchase_orders WHERE deleted_at IS NULL
 ), so AS (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE contract_id IS NOT NULL) AS under_contract
      FROM sales_orders WHERE deleted_at IS NULL
 ), con AS (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE status = 'active') AS active,
           count(*) FILTER (WHERE side = 'buy') AS buy_side,
           count(*) FILTER (WHERE side = 'sell') AS sell_side
      FROM contracts WHERE deleted_at IS NULL
 )
 SELECT po.total AS purchase_orders_total,
    po.under_contract AS purchase_orders_under_contract,
    so.total AS sales_orders_total,
    so.under_contract AS sales_orders_under_contract,
    con.total AS contracts_total,
    con.active AS contracts_active,
    con.buy_side AS contracts_buy_side,
    con.sell_side AS contracts_sell_side,
    -- 【能不能判品位】要三样都在:挂了合同的单、它的入库、以及化验。
    -- 这个数是 contract_grade_breaches 那张表的【分母】——
    -- 没有它,「0 条违反」说不出自己是哪一种 0。
    (SELECT count(*) FROM contract_document_terms t
      WHERE jsonb_array_length(t.grade_specs) > 0) AS documents_with_grade_specs
   FROM po, so, con
  WHERE has_permission('module.suppliers.view'::text)
     OR has_permission('module.customers.view'::text);

COMMENT ON VIEW public.contract_coverage IS
    'CONTRACT-1:多少张单据跑在合同之下,多少张没有 —— ★**没有它,那道闸会撒谎**★(Tim 2026-08-29)。本刀没有强制任何单据挂合同,而那是对的(现货采购本来就没有合同),后果是覆盖率完全自愿 —— 于是**「没有任何合同被违反」很可能只意味着「没有人挂过任何东西」**,而两句话必须分得开。分开它们的唯一办法是把分母摆出来。与 PARTY-1 的重叠报告同一条:那一份因为客户侧一个 tax_id 都没有,「0 条重叠」必然为真而毫无信息,所以它带着 coverage 一起返回 —— **一个永远为真的判词是装饰**。`documents_with_grade_specs` 是 contract_grade_breaches 的分母。**它不评判覆盖率高低**:没有人裁过"多少比例的采购应当在合同之下",现货买卖是正当的商业形态,不是待修的缺口 —— 所以只报数,不报警。';


COMMIT;
