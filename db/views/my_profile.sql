-- db/views/my_profile.sql
-- 员工自助的那一行:当前登录者自己的档案 + 部门、直属上级、培训条数、最近薪资期间。
-- 属主权限 + 视图体里的 current_user_employee() 谓词。账号没关联员工档案时自然是零行。
-- 【敏感列照给】—— 身份证件号、准证号是这个人自己的数据。
--
-- NOTE: introduced/updated by db/migrations/2026-08-02-perm4-self-service.sql.

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
    e.annual_leave_days,
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
