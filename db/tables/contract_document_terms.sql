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
-- NOTE: introduced by db/migrations/2026-08-30-contract1-the-contract-register.sql.
-- First-run script (plain CREATEs).

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
    -- PRICE-1:计价条款的快照:[{metal, base_event, qp_months, index_code, payable_pct}, …]
    -- 【与 grade_specs 同一形状、同一理由】**空数组合法**(合同可以不约指数定价),
    -- 而 NULL 不合法 —— "没有计价条款"与"没抄"必须分得开。
    -- ★【它【没有】暂定价】★ 暂定价是逐笔谈的(§6.2),不是条款,所以它不在合同上,
    --   也就不在这份合同条款的副本里。见 contract_pricing_terms 的表注。
    pricing_terms      jsonb NOT NULL DEFAULT '[]'::jsonb,
    CONSTRAINT contract_document_terms_exactly_one_document
        CHECK (num_nonnulls(purchase_order_id, sales_order_id) = 1),
    CONSTRAINT contract_document_terms_grade_specs_is_array
        CHECK (jsonb_typeof(grade_specs) = 'array'),
    CONSTRAINT contract_document_terms_pricing_terms_is_array
        CHECK (jsonb_typeof(pricing_terms) = 'array')
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

COMMENT ON COLUMN public.contract_document_terms.pricing_terms IS
    'PRICE-1:挂上去那一刻抄下来的**计价条款**快照 —— 与 grade_specs 同一形状、同一理由(抄不是引用)。★★**冻结的时刻是【挂接】,不是【下单】**★★:CONTRACT-1 刻意允许**回填挂接**(单据日期落在合同期外不拒,因为回填是正当操作),所以一次事后补挂会把**挂接当时**在效的条款冻上去,而不是下单当天的。**对品位规格这条边不算锋利,对钱锋利** —— 所以 link_document_to_contract 的返回里带 terms_frozen_as_of 与 TERMS_FROZEN_AT_LINK_TIME,/contracts 页也把它印出来,好让挂接的人**当场看见自己冻的是哪一份**。**不要去"修"回填权限** —— 那是 CONTRACT-1 裁过的,它站得住。★**它没有暂定价**★:暂定价逐笔谈(§6.2),不是条款。';
