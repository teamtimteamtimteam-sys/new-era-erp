-- db/views/employee_directory.sql
-- 员工目录:一名【在册】员工一行。读遮蔽伴生视图而非基表,遮蔽因此是继承来的。
-- 年假三列(年度费率 / 已累积 / 可请)同样继承自 employees_masked。
-- SECURITY INVOKER。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE VIEW public.employee_directory WITH (security_invoker = on) AS
 SELECT e.id AS employee_id,
    e.code,
    e.legal_name,
    e.preferred_name,
    e.department_id,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    e.job_title,
    e.manager_id,
    mgr.code AS manager_code,
    mgr.legal_name AS manager_name,
    e.employment_type,
    e.work_category,
    e.employment_status,
    e.hire_date,
    e.probation_end_date,
    e.annual_leave_rate_days,
    e.annual_leave_accrued_days,
    e.annual_leave_available_days,
    e.residency_status,
    e.work_pass_type,
    e.work_pass_expiry_date,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::integer
            ELSE e.work_pass_expiry_date - CURRENT_DATE
        END AS days_to_work_pass_expiry,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::text
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 90 THEN 'warning'::text
            ELSE NULL::text
        END AS work_pass_alert,
    pay.gross_pay AS current_gross_pay,
    pay.period_month AS current_pay_period,
    COALESCE(tr.training_count, 0::bigint) AS training_count
   FROM employees_masked e
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees_masked mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT pl.gross_pay,
            pp.period_month
           FROM payroll_lines_masked pl
             JOIN payroll_periods pp ON pp.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND pp.status = 'posted'::text AND pp.deleted_at IS NULL
          ORDER BY pp.period_month DESC
         LIMIT 1) pay ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS training_count
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
  WHERE e.deleted_at IS NULL;
