-- db/views/my_self_assessment_goals.sql
-- 自评期间,被评估人读得到的【目标行】:目标、指标、单位,以及他自己写的结果与实际值。
-- 【看不到 reviewer_assessment_text】那是评估人对他的评价,批准之后才该看见。
-- 谓词与 my_self_assessment 相同:本人 + 且仅在 self_review。
--
-- NOTE: introduced/updated by db/migrations/2026-08-09-hr3c-quantified-goals-and-self-assessment-read.sql.

CREATE VIEW public.my_self_assessment_goals WITH (security_invoker = off) AS
 SELECT g.id AS goal_id,
    g.review_id,
    g.sequence,
    g.objective_text,
    g.target_value,
    g.unit,
    g.employee_result_text,
    g.actual_value
   FROM review_goals g
     JOIN performance_reviews r ON r.id = g.review_id
  WHERE r.employee_id = current_user_employee() AND r.status = 'self_review'::text
  ORDER BY g.sequence;
