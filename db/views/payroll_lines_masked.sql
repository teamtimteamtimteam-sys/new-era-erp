-- db/views/payroll_lines_masked.sql
-- 薪资明细的遮蔽伴生视图。按人头的五个金额要 data.view_pay ——
-- 【但对本人让路】:行谓词与列遮蔽都带 "OR employee_id = current_user_employee()"。
-- 两处必须同时加:只加行谓词 → 看得见自己的行但金额是空的;只加列遮蔽 → 行根本取不出来。
-- 这是遮蔽唯一让路的场合 —— 让多了泄露所有人的工资,让少了藏起本人的工资。
--
-- NOTE: introduced/updated by db/migrations/2026-08-02-perm4-self-service.sql.

CREATE VIEW public.payroll_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    payroll_period_id,
    employee_id,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN gross_pay
            ELSE NULL::numeric
        END AS gross_pay,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN employer_cpf
            ELSE NULL::numeric
        END AS employer_cpf,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN employee_cpf
            ELSE NULL::numeric
        END AS employee_cpf,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN other_deductions
            ELSE NULL::numeric
        END AS other_deductions,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN net_pay
            ELSE NULL::numeric
        END AS net_pay,
    notes,
    created_at,
    paid_at,
    paid_journal_entry_id
   FROM payroll_lines
  WHERE has_permission('module.hr.view'::text) OR employee_id = current_user_employee() OR has_permission('module.finance.view'::text) AND has_permission('data.view_pay'::text);
