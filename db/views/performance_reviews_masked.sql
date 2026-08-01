-- db/views/performance_reviews_masked.sql
-- 绩效评估的遮蔽伴生视图。new_monthly_salary 是薪酬数据,要 data.view_pay,
-- 【对本人让路】—— 那是这个人自己被谈定的新工资,评估一旦批准就该由他自己看见。
-- 行谓词是基表三条 SELECT 策略的逐字重述:HR 模块 / 本行的评估人 /
-- 本人【且已批准或已确认】。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.

CREATE VIEW public.performance_reviews_masked WITH (security_invoker = off) AS
 SELECT id,
    employee_id,
    review_type,
    cycle_id,
    period_start,
    period_end,
    reviewer_employee_id,
    status,
    rating_code,
    summary_text,
    self_assessment_text,
    probation_outcome,
        CASE
            WHEN has_permission('data.view_pay'::text) OR employee_id = current_user_employee() THEN new_monthly_salary
            ELSE NULL::numeric
        END AS new_monthly_salary,
    salary_effective_date,
    submitted_at,
    submitted_by,
    approved_at,
    approved_by,
    acknowledged_at,
    void_reason,
    voided_at,
    voided_by,
    notes,
    created_at,
    created_by,
    updated_at,
    updated_by
   FROM performance_reviews
  WHERE has_permission('module.hr.view'::text) OR reviewer_employee_id = current_user_employee() OR employee_id = current_user_employee() AND (status = ANY (ARRAY['approved'::text, 'acknowledged'::text]));
