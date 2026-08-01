-- db/views/employees_masked.sql
-- 员工档案的遮蔽伴生视图。身份与联系方式要 data.view_identity,
-- 合同月薪 monthly_salary 要 data.view_pay —— 两者同样【对本人让路】。
--
-- 【monthly_salary_set 不遮蔽】"有没有录工资"不是敏感信息,"是多少"才是。
-- hr_alerts(SECURITY INVOKER)与列表页要能问"谁还没录"。
--
-- 【新列一律追加在末尾】employee_directory 依赖本视图;只在尾部加列,
-- CREATE OR REPLACE 就能原地改,依赖视图一个都不用动(DROP 会要 CASCADE)。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql;
--       updated by db/migrations/2026-08-03-hr3a-performance-reviews.sql and
--       db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql.

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
    annual_leave_days,
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
    review_exempt
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();
