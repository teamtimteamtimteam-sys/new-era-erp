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
-- NOTE: introduced by db/migrations/2026-08-30-contract1-the-contract-register.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

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
