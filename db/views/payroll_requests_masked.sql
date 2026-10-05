-- db/views/payroll_requests_masked.sql
-- U1-A(UNBLOCK-1 Q10,2026-10-05):工资申请的遮蔽伴生视图。snapshot(逐行的员工 · 应发 · 公积金……)、gross_total 与 amount_base
--   要 data.view_pay —— 与这一期的合计同一个判据(Q9)。
-- 行谓词 = 基表的读策略(module.hr.view)。每一列都在这里(colgrant)。判据与 change_log_mask_rules 的 code:data.view_pay 同一个。

CREATE VIEW public.payroll_requests_masked WITH (security_invoker = off) AS
 SELECT id,
    payroll_period_id,
    kind,
    status,
    label,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN snapshot
            ELSE NULL::jsonb
        END AS snapshot,
    currency,
    fx_rate,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN gross_total
            ELSE NULL::numeric
        END AS gross_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    notes,
    decided_at,
    decided_by,
    decision_notes,
    withdrawn_at,
    withdrawn_by,
    executed_at,
    executed_by,
    result_journal_entry_id,
    created_at,
    created_by
   FROM payroll_requests
  WHERE has_permission('module.hr.view'::text);

COMMENT ON VIEW public.payroll_requests_masked IS
    'U1-A(UNBLOCK-1 Q10):工资申请的遮蔽伴生视图。snapshot / gross_total / amount_base 要 data.view_pay;行谓词 = 基表的读策略(module.hr.view)。';

GRANT SELECT ON public.payroll_requests_masked TO authenticated;
