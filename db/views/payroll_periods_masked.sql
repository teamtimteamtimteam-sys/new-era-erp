-- db/views/payroll_periods_masked.sql
-- U1-A(UNBLOCK-1 Q9,2026-10-05):工资期的遮蔽伴生视图。五个合计要 data.view_pay —— 一期只有一两个人时,合计就是一个人的工资。
--   不对本人让路:一期的合计不是"他自己的",是这一期所有人的(本人在 /me 上读自己那一行工资,经 payroll_lines_masked)。
--   与财务那一侧的 payroll_period_lookup 同一个判据(Q9:一条规矩,不按人数设门槛)。
-- 行谓词 = 基表的读策略(module.hr.view)。每一列都在这里(colgrant)。判据与 change_log_mask_rules 的 code:data.view_pay 同一个。

CREATE VIEW public.payroll_periods_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    period_month,
    payment_date,
    currency,
    fx_rate,
    status,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN gross_total
            ELSE NULL::numeric
        END AS gross_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN employer_cpf_total
            ELSE NULL::numeric
        END AS employer_cpf_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN employee_cpf_total
            ELSE NULL::numeric
        END AS employee_cpf_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN other_deductions_total
            ELSE NULL::numeric
        END AS other_deductions_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN net_pay_total
            ELSE NULL::numeric
        END AS net_pay_total,
    journal_entry_id,
    source_note,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    cpf_paid_at,
    cpf_journal_entry_id,
    deductions_paid_at,
    deductions_journal_entry_id
   FROM payroll_periods
  WHERE has_permission('module.hr.view'::text);

COMMENT ON VIEW public.payroll_periods_masked IS
    'U1-A(UNBLOCK-1 Q9):工资期的遮蔽伴生视图。五个合计要 data.view_pay(不按人数设门槛,不对本人让路);行谓词 = 基表的读策略(module.hr.view)。';

GRANT SELECT ON public.payroll_periods_masked TO authenticated;
