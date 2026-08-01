-- db/views/employee_directory.sql
-- 员工目录:一名【在册】员工一行。部门名中英两列都给 —— 视图不猜界面语言。
--
-- 【受限访问】current_gross_pay / current_pay_period 派生自 payroll_lines
-- (最近一个【已过账】周期里该员工那一行),属于个人薪酬,权限切次按薪酬口径管控。
-- 其余列是一般员工目录信息。
--
-- work_pass_alert 的档期与 hr_alerts 一致:过期 / 30 天内 critical / 90 天内 warning。
-- SECURITY INVOKER。
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql.

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的,视图体其余部分逐字未变。它仍然是 SECURITY INVOKER:
-- 它读的遮蔽视图自带模块谓词,所以既拿得到数据,也绕不过任何模块边界。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.
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
    e.annual_leave_days,
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
