-- db/views/my_profile.sql
-- 员工自助的那一行。属主权限 + 视图体里的 current_user_employee() 谓词。
-- 【敏感列照给】—— 那是这个人自己的数据。年假三列同 employees_masked(HR-2c)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE VIEW public.my_profile WITH (security_invoker = off) AS
 SELECT e.id AS employee_id,
    e.code,
    e.legal_name,
    e.preferred_name,
    e.job_title,
    e.employment_type,
    e.work_category,
    e.employment_status,
    e.hire_date,
    e.probation_end_date,
    annual_leave_rate_per_month(e.id) AS annual_leave_rate_days_per_month,
    annual_leave_rate_per_month(e.id) * 12::numeric AS annual_leave_rate_days,
    accrued_annual_leave(e.id) AS annual_leave_accrued_days,
    (leave_balance_internal(e.id, 'annual'::text) ->> 'available'::text)::numeric AS annual_leave_available_days,
    e.residency_status,
    e.work_pass_type,
    e.work_pass_no,
    e.work_pass_issue_date,
    e.work_pass_expiry_date,
    e.identity_no,
    e.work_email,
    e.work_phone,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    mgr.legal_name AS manager_name,
    mgr.code AS manager_code,
    COALESCE(tr.cnt, 0::bigint) AS training_count,
    pp.code AS latest_payroll_code,
    pp.period_month AS latest_payroll_month
   FROM employees e
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT count(*) AS cnt
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
     LEFT JOIN LATERAL ( SELECT p.code,
            p.period_month
           FROM payroll_lines pl
             JOIN payroll_periods p ON p.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND p.status = 'posted'::text AND p.deleted_at IS NULL
          ORDER BY p.period_month DESC
         LIMIT 1) pp ON true
  WHERE e.id = current_user_employee() AND e.deleted_at IS NULL;
