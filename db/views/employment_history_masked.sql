-- db/views/employment_history_masked.sql
-- 任职履历的遮蔽伴生视图。HR-3a 给履历加了 old_monthly_salary / new_monthly_salary
-- 两列记调薪 —— 那是薪酬数据,要 data.view_pay,【对本人让路】。
-- 行谓词照抄基表的两条 SELECT 策略(module.hr.view 或本人),属主权限的视图
-- 必须自己把行访问加回来,不能比基表更宽。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.

CREATE VIEW public.employment_history_masked WITH (security_invoker = off) AS
 SELECT id,
    employee_id,
    effective_date,
    change_type,
    job_title,
    department_id,
    employment_type,
    employment_status,
    notes,
    created_at,
    created_by,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN old_monthly_salary
            ELSE NULL::numeric
        END AS old_monthly_salary,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN new_monthly_salary
            ELSE NULL::numeric
        END AS new_monthly_salary,
    -- 后加的列,补于 2026-08-04-fin7-fu-masked-grant-gaps(基表有列权限,视图里却
    -- 没有这一列,经视图选它会 42703 —— 与 processing_cost_entries 同一类缺口)
    work_category,
    -- PDPA-1-fu:不遮蔽 —— "这一行还保不保有薪资"本身不是薪资数据。
    anonymised_at
   FROM employment_history
  WHERE has_permission('module.hr.view'::text) OR employee_id = current_user_employee();
