-- db/views/employees_masked.sql
-- 员工档案的遮蔽伴生视图。身份/联系方式要 data.view_identity,月固定工资要 data.view_pay,
-- 两者都【对本人让路】。
--
-- 【年假三列都是派生的】annual_leave_days 那一列已随 HR-2c 删除。
--   annual_leave_rate_days       年度【费率】,界面必须按费率标,不是余额
--   annual_leave_accrued_days    到今天已经挣到的
--   annual_leave_available_days  扣掉已请、加上结转后真正能请的
-- 软删的行用 deleted_at 守卫(那些函数对已删除员工会报错)。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE VIEW public.employees_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    legal_name,
    preferred_name,
    department_id,
    job_title,
    manager_id,
    employment_type,
    work_category,
    hire_date,
    probation_end_date,
    employment_status,
    separation_date,
    separation_type,
    separation_notes,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_email
            ELSE NULL::text
        END AS work_email,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_phone
            ELSE NULL::text
        END AS work_phone,
    residency_status,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN identity_no
            ELSE NULL::text
        END AS identity_no,
    work_pass_type,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_pass_no
            ELSE NULL::text
        END AS work_pass_no,
    work_pass_issue_date,
    work_pass_expiry_date,
    user_id,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    confirmation_date,
        CASE
            WHEN has_permission('data.view_pay'::text) OR id = current_user_employee() THEN monthly_salary
            ELSE NULL::numeric
        END AS monthly_salary,
    monthly_salary_set,
    review_exempt,
        CASE
            WHEN deleted_at IS NULL THEN annual_leave_rate_per_year(id)
            ELSE NULL::numeric
        END AS annual_leave_rate_days,
        CASE
            WHEN deleted_at IS NULL THEN accrued_annual_leave(id)
            ELSE NULL::numeric
        END AS annual_leave_accrued_days,
        CASE
            WHEN deleted_at IS NULL THEN (leave_balance_internal(id, 'annual'::text) ->> 'available'::text)::numeric
            ELSE NULL::numeric
        END AS annual_leave_available_days
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();
