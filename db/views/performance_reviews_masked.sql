-- db/views/performance_reviews_masked.sql
-- 绩效评估的遮蔽伴生视图。new_monthly_salary 要 data.view_pay,【对本人让路】。
--
-- 行谓词是基表三条 SELECT 策略的逐字重述,HR-3b 之后第一条多了一个合取项:
--   (module.hr.view AND data.view_reviews) / 本行的评估人 / 本人且已批准或已确认。
-- 【评估人与被评估人两条豁免不依赖 data.view_reviews】—— 读自己评的那份、读自己那份
-- 已批准的,与"有没有资格通读全公司的评估"是两件事。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql;
--       updated by db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql.

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
    updated_by,
    self_assessment_submitted_at
   FROM performance_reviews
  WHERE has_permission('module.hr.view'::text) AND has_permission('data.view_reviews'::text) OR reviewer_employee_id = current_user_employee() OR employee_id = current_user_employee() AND (status = ANY (ARRAY['approved'::text, 'acknowledged'::text]));
