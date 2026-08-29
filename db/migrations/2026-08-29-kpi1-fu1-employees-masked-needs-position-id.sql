-- KPI-1 fu1:employees_masked 补上 position_id。
-- 【为什么必须补】employees 是遮蔽表,而 gate 的 colgrant 那一条要求它的每一列
-- 要么被列授权、要么出现在 _masked 视图里 —— WO-1a 记过这一课:
-- ADD COLUMN、GRANT、_masked 三件事要在【同一次迁移】里做完,而我漏了第三件。
-- 顺带:编辑员工那张表单读的就是这张视图,没有这一列它取不到当前职位。
BEGIN;
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
--       PDPA-1 追加 anonymised_at / anonymised_by —— **排在末尾**,因为
--       CREATE OR REPLACE VIEW 只许追加,不许改动既有列的次序。两列都不遮蔽:
--       "这一行已经不再保有个人数据"这件事本身不是个人数据,而且必须看得见。

CREATE OR REPLACE VIEW public.employees_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    legal_name,
    preferred_name,
    department_id,
    -- KPI-1:employees.job_title 已删,头衔改从【职位】来。
    -- **列名保持 job_title**,是为了不惊动这张视图的下游读者 ——
    -- 它回答的仍然是同一个问题(这个人的头衔是什么),只是真源换了。
    (SELECT p.title FROM positions p WHERE p.id = employees.position_id) AS job_title,
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
        END AS annual_leave_available_days,
    anonymised_at,
    anonymised_by,
    -- KPI-1:新列加在【末尾】—— CREATE OR REPLACE VIEW 只允许末尾追加列。
    -- 【它必须出现在这张视图里】employees 是遮蔽表,而 colgrant 那道闸要求它的
    -- 每一列要么被列授权、要么出现在 _masked 里(WO-1a 那一课)。
    position_id
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();
COMMIT;
