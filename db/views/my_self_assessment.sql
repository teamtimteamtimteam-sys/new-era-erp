-- db/views/my_self_assessment.sql
-- 自评期间,被评估人读得到的【评估抬头】。
-- 【HR-3b 定错的那条规则在这里被修正】原来"批准前什么都读不到"让自评根本没法写。
-- 这个视图窄到只够写自评:本人 + 且仅在 status='self_review'。
-- 【列清单就是权限边界】rating_code / summary_text / probation_outcome / 薪酬两列
-- 一个都不在 SELECT 里,所以任何人都读不出来。
-- draft 阶段与 submitted-未批准阶段,本视图【零行】—— 与基表策略一致。
--
-- NOTE: introduced/updated by db/migrations/2026-08-09-hr3c-quantified-goals-and-self-assessment-read.sql.

CREATE VIEW public.my_self_assessment WITH (security_invoker = off) AS
 SELECT r.id AS review_id,
    r.employee_id,
    r.review_type,
    r.cycle_id,
    c.name AS cycle_name,
    r.period_start,
    r.period_end,
    r.status,
    r.self_assessment_text,
    r.self_assessment_submitted_at
   FROM performance_reviews r
     LEFT JOIN review_cycles c ON c.id = r.cycle_id
  WHERE r.employee_id = current_user_employee() AND r.status = 'self_review'::text;
