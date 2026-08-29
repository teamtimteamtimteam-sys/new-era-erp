-- db/views/my_profile.sql
-- 员工自助的那一行。属主权限 + 视图体里的 current_user_employee() 谓词。
-- 【敏感列照给】—— 那是这个人自己的数据。年假三列同 employees_masked。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE VIEW public.my_profile WITH (security_invoker = off) AS
 SELECT e.id AS employee_id,
    e.code,
    e.legal_name,
    e.preferred_name,
    -- KPI-1:employees.job_title 已删,头衔改从【职位】来。
    -- 列名保持 job_title,是为了让 /me 那一格与它的历史记录读起来仍然是同一件事
    -- (employment_history.job_title 是那一天的文本快照,这里是"今天的")。
    pos.title AS job_title,
    e.employment_type,
    e.work_category,
    e.employment_status,
    e.hire_date,
    e.probation_end_date,
    annual_leave_rate_per_year(e.id) AS annual_leave_rate_days,
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
    pp.period_month AS latest_payroll_month,
    -- KPI-1:【新列加在末尾】—— CREATE OR REPLACE VIEW 只允许在末尾追加列,
    -- 中间插一列要 DROP + 重建,而这张视图有下游读者。
    pos.code AS position_code
   FROM employees e
     LEFT JOIN positions pos ON pos.id = e.position_id
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
