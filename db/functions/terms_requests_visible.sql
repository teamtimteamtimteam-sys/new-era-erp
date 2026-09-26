-- db/functions/terms_requests_visible.sql
-- APR-8(2026-09-26,grilling Q8):公式页与合同页上那一块读的就是这里 —— cco 看得见自己提的申请,CFO 看得见要他批的。
--   公式申请:持 module.pricing.view 的人;snapshot / proposed 按 pricing_formula_terms_visible(那张公式的方向)给,
--     没有那个价格码的读者读 NULL(与 pricing_formulas_masked 同一条)。
--   合同申请:跟着合同那一侧走(module.suppliers.view / module.customers.view,contracts 自己的读策略同一条)。
--   只给在等的全部 + 最近决定 / 撤回的 p_recent 张;raised_by_me = 提单人就是读者这个人(按人认)。
--   p_formula_id / p_contract_id 给了就只给那一个主体的。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_requests_visible(p_recent integer DEFAULT 10, p_formula_id uuid DEFAULT NULL::uuid, p_contract_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, kind text, status text, label text, formula_id uuid, contract_id uuid, subject_code text, reason text, proposed jsonb, snapshot jsonb, created_at timestamp with time zone, created_by_email text, raised_by_me boolean, decided_at timestamp with time zone, decided_by_email text, decision_notes text, withdrawn_at timestamp with time zone, withdraw_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               COALESCE(f.code, c.code) AS subject_code,
               CASE WHEN q.formula_id IS NOT NULL THEN pricing_formula_terms_visible(f.direction) ELSE true END AS terms_ok,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM terms_requests q
          LEFT JOIN pricing_formulas f ON f.id = q.formula_id
          LEFT JOIN contracts c ON c.id = q.contract_id
         WHERE (p_formula_id IS NULL OR q.formula_id = p_formula_id)
           AND (p_contract_id IS NULL OR q.contract_id = p_contract_id)
           AND ((q.formula_id IS NOT NULL AND has_permission('module.pricing.view'))
             OR (q.contract_id IS NOT NULL
                 AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'))
                   OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'))))))
    SELECT r.id, r.kind, r.status, r.label, r.formula_id, r.contract_id, r.subject_code, r.reason,
           CASE WHEN r.terms_ok THEN r.proposed END,
           CASE WHEN r.terms_ok THEN r.snapshot END,
           r.created_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.created_by),
           self_leg(r.created_by, NULL, auth.uid()) = 'raiser',
           r.decided_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.decided_by),
           r.decision_notes, r.withdrawn_at, r.withdraw_reason
      FROM r
     WHERE r.is_open OR r.rn <= GREATEST(COALESCE(p_recent, 10), 0)
     ORDER BY r.is_open DESC, COALESCE(r.decided_at, r.withdrawn_at, r.created_at) DESC
$function$;
