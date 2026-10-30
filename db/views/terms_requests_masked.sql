-- db/views/terms_requests_masked.sql
-- GOLIVE-2(Tim 2026-10-30 Q6):遮蔽伴生视图 —— terms_requests 的每一列都在;快照(snapshot)对不持那一侧价格码的读者整份置空:
--   公式申请照 pricing_formula_terms_visible(公式的 direction),合同申请照 contract_terms_price_visible(contract_id)
--   (客户合同 data.view_prices,供应商合同 data.view_purchase_prices)—— 与 terms_requests_visible() 同一个判据。
--   proposed 不遮:合同申请那一列恒为 NULL,而公式申请的行只给同时持 module.pricing.view 与两个价格码的人(下面那句行门)。
-- 【属主权限】把条款申请表的读策略原样写回视图体 —— 属主绕过行级策略,漏写就把行交给了每一个人。屏幕仍读 terms_requests_visible();
--   这张视图是给直读这张表的路(PostgREST)留的唯一一扇门:基表的 snapshot 列从此不再授给 authenticated。
-- 变更记录里 snapshot 整列受限(change_log_mask_rules 的 tr_snapshot)。
--
-- NOTE: introduced by db/migrations/2026-10-30-golive-2.sql.

CREATE VIEW public.terms_requests_masked WITH (security_invoker = off) AS
 SELECT
    q.id,
    q.kind,
    q.status,
    q.label,
    q.formula_id,
    q.contract_id,
    q.reason,
    q.proposed,
        CASE
            WHEN (CASE WHEN q.formula_id IS NOT NULL THEN pricing_formula_terms_visible(f.direction)
                       ELSE contract_terms_price_visible(q.contract_id) END) THEN q.snapshot
            ELSE NULL::jsonb
        END AS snapshot,
    q.fingerprint,
    q.decided_at,
    q.decided_by,
    q.decision_notes,
    q.executed_at,
    q.withdrawn_at,
    q.withdrawn_by,
    q.withdraw_reason,
    q.created_at,
    q.created_by
   FROM terms_requests q
     LEFT JOIN pricing_formulas f ON f.id = q.formula_id
     LEFT JOIN contracts c ON c.id = q.contract_id
  WHERE (q.formula_id IS NOT NULL AND ( SELECT has_permission('module.pricing.view'::text) AS has_permission)
            AND ( SELECT has_permission('data.view_prices'::text) AS has_permission)
            AND ( SELECT has_permission('data.view_purchase_prices'::text) AS has_permission))
     OR (q.contract_id IS NOT NULL
         AND ((c.customer_id IS NOT NULL AND ( SELECT has_permission('module.customers.view'::text) AS has_permission))
           OR (c.supplier_id IS NOT NULL AND ( SELECT has_permission('module.suppliers.view'::text) AS has_permission))));

REVOKE ALL ON public.terms_requests_masked FROM authenticated, anon;
GRANT SELECT ON public.terms_requests_masked TO authenticated;
