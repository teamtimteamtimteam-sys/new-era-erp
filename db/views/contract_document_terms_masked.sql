-- db/views/contract_document_terms_masked.sql
-- GOLIVE-2(Tim 2026-10-30 Q4):遮蔽伴生视图 —— contract_document_terms(合同挂到销售单 / 采购单那一刻冻结的条款副本)的每一列都在,
--   只有三样价格在 jsonb 里置空:pricing_terms[].payable_pct · settlement_terms.refining_charges[].usd_per_tonne_of_metal ·
--   settlement_terms.penalty_elements[].usd_per_tonne_per_pct_over。品位规格、质量限值、争议与留样条款照旧可见(质量那几支要读它们)。
--   码按【副本自己那一侧】:销售单 → data.view_prices,采购单 → data.view_purchase_prices(判据只在 contract_copy_price_visible 一处)。
-- 【属主权限】把副本表的读策略原样写回视图体(客户合同 → module.customers.view,供应商合同 → module.suppliers.view)——
--   属主绕过行级策略,漏写这一句就把行交给了每一个人。判断写成按语句求一次的 (SELECT has_permission(…))。
-- 变更记录里这两列整列受限(change_log_mask_rules 的 cdt_price)。
--
-- NOTE: introduced by db/migrations/2026-10-30-golive-2.sql.

CREATE VIEW public.contract_document_terms_masked WITH (security_invoker = off) AS
 SELECT
    t.id,
    t.purchase_order_id,
    t.sales_order_id,
    t.contract_id,
    t.contract_code,
    t.contract_title,
    t.incoterm,
    t.currency,
    t.payment_terms_days,
    t.grade_specs,
    t.linked_at,
    t.linked_by,
        CASE
            WHEN contract_copy_price_visible(t.sales_order_id, t.purchase_order_id) THEN t.pricing_terms
            ELSE ( SELECT COALESCE(jsonb_agg(CASE WHEN jsonb_typeof(e.value) = 'object' AND e.value ? 'payable_pct'
                                                   THEN jsonb_set(e.value, '{payable_pct}', 'null'::jsonb) ELSE e.value END
                                              ORDER BY e.ordinality), '[]'::jsonb)
                     FROM jsonb_array_elements(t.pricing_terms) WITH ORDINALITY e(value, ordinality))
        END AS pricing_terms,
        CASE
            WHEN contract_copy_price_visible(t.sales_order_id, t.purchase_order_id) THEN t.settlement_terms
            ELSE t.settlement_terms
                 || CASE WHEN jsonb_typeof(t.settlement_terms -> 'refining_charges') = 'array' THEN jsonb_build_object('refining_charges',
                        ( SELECT COALESCE(jsonb_agg(CASE WHEN jsonb_typeof(r.value) = 'object' AND r.value ? 'usd_per_tonne_of_metal'
                                                         THEN jsonb_set(r.value, '{usd_per_tonne_of_metal}', 'null'::jsonb) ELSE r.value END
                                                    ORDER BY r.ordinality), '[]'::jsonb)
                            FROM jsonb_array_elements(t.settlement_terms -> 'refining_charges') WITH ORDINALITY r(value, ordinality)))
                         ELSE '{}'::jsonb END
                 || CASE WHEN jsonb_typeof(t.settlement_terms -> 'penalty_elements') = 'array' THEN jsonb_build_object('penalty_elements',
                        ( SELECT COALESCE(jsonb_agg(CASE WHEN jsonb_typeof(p.value) = 'object' AND p.value ? 'usd_per_tonne_per_pct_over'
                                                         THEN jsonb_set(p.value, '{usd_per_tonne_per_pct_over}', 'null'::jsonb) ELSE p.value END
                                                    ORDER BY p.ordinality), '[]'::jsonb)
                            FROM jsonb_array_elements(t.settlement_terms -> 'penalty_elements') WITH ORDINALITY p(value, ordinality)))
                         ELSE '{}'::jsonb END
        END AS settlement_terms
   FROM contract_document_terms t
     JOIN contracts c ON c.id = t.contract_id
  WHERE (c.customer_id IS NOT NULL AND ( SELECT has_permission('module.customers.view'::text) AS has_permission))
     OR (c.supplier_id IS NOT NULL AND ( SELECT has_permission('module.suppliers.view'::text) AS has_permission));

REVOKE ALL ON public.contract_document_terms_masked FROM authenticated, anon;
GRANT SELECT ON public.contract_document_terms_masked TO authenticated;
