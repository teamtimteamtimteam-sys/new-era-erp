-- db/views/contract_insurance_obligations_masked.sql
-- GOLIVE-1 第 12 行(Tim 2026-10-25 TABLE-EXPORT-3c Q3 · 2026-10-29 Q9):遮蔽伴生视图 —— contract_insurance_obligations 的每一列都在,保险最低金额按合同那一侧置空
--   (客户合同 → data.view_prices,供应商合同 → data.view_purchase_prices;判据只在 contract_terms_price_visible 一处)。币种不遮。
-- 【属主权限】把条款表的读策略原样写回视图体(客户合同 → module.customers.view,供应商合同 → module.suppliers.view)——
--   属主绕过行级策略,漏写这一句就把行交给了每一个人。判断写成按语句求一次的 (SELECT has_permission(…))。
--
-- NOTE: introduced by db/migrations/2026-10-29-golive-1.sql.

CREATE VIEW public.contract_insurance_obligations_masked WITH (security_invoker = off) AS
 SELECT
    t.id,
    t.contract_id,
    t.insured_by,
    t.cover_type,
        CASE
            WHEN contract_terms_price_visible(t.contract_id) THEN t.min_amount
            ELSE NULL::numeric
        END AS min_amount,
    t.currency,
    t.notes,
    t.created_at,
    t.created_by,
    t.updated_at,
    t.updated_by
   FROM contract_insurance_obligations t
     JOIN contracts c ON c.id = t.contract_id
  WHERE (c.customer_id IS NOT NULL AND ( SELECT has_permission('module.customers.view'::text) AS has_permission))
     OR (c.supplier_id IS NOT NULL AND ( SELECT has_permission('module.suppliers.view'::text) AS has_permission));

REVOKE ALL ON public.contract_insurance_obligations_masked FROM authenticated, anon;
GRANT SELECT ON public.contract_insurance_obligations_masked TO authenticated;
