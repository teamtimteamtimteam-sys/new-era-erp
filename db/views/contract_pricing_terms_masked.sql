-- db/views/contract_pricing_terms_masked.sql
-- GOLIVE-1 第 12 行(Tim 2026-10-25 TABLE-EXPORT-3c Q3 · 2026-10-29 Q9):遮蔽伴生视图 —— contract_pricing_terms 的每一列都在,payable_pct 按合同那一侧置空
--   (客户合同 → data.view_prices,供应商合同 → data.view_purchase_prices;判据只在 contract_terms_price_visible 一处)。
-- 【属主权限】把条款表的读策略原样写回视图体(客户合同 → module.customers.view,供应商合同 → module.suppliers.view)——
--   属主绕过行级策略,漏写这一句就把行交给了每一个人。判断写成按语句求一次的 (SELECT has_permission(…))。
--
-- NOTE: introduced by db/migrations/2026-10-29-golive-1.sql.

CREATE VIEW public.contract_pricing_terms_masked WITH (security_invoker = off) AS
 SELECT
    t.id,
    t.contract_id,
    t.metal,
    t.base_event,
    t.qp_months,
    t.index_code,
        CASE
            WHEN contract_terms_price_visible(t.contract_id) THEN t.payable_pct
            ELSE NULL::numeric
        END AS payable_pct,
    t.notes,
    t.created_at,
    t.created_by,
    t.updated_at,
    t.updated_by
   FROM contract_pricing_terms t
     JOIN contracts c ON c.id = t.contract_id
  WHERE (c.customer_id IS NOT NULL AND ( SELECT has_permission('module.customers.view'::text) AS has_permission))
     OR (c.supplier_id IS NOT NULL AND ( SELECT has_permission('module.suppliers.view'::text) AS has_permission));

REVOKE ALL ON public.contract_pricing_terms_masked FROM authenticated, anon;
GRANT SELECT ON public.contract_pricing_terms_masked TO authenticated;
