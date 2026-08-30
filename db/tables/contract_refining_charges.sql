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
-- NOTE: introduced by db/migrations/2026-08-30-settle1-the-settlement-basis.sql.
-- First-run script (plain CREATEs).

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
