-- db/views/my_review_subjects.sql
-- 评估人读得到的被评估人名录:每份"我评的评估"一行。
-- employees 的 SELECT 是 module.hr.view 或本人,零 HR 权限的部门经理据此读不到
-- 被评估人的名字 —— /my-reviews 会只剩一串 uuid。修法沿用 cut 2b 的属主权限视图:
-- 行谓词把基表那条 "select as reviewer" 策略【原样】写进视图体。
-- 【列清单就是权限边界】工号、姓名、职务、部门名、评估轮名;
-- 没有薪酬、没有证件号、没有银行、没有在职状态。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-ui-read-support.sql.

CREATE VIEW public.my_review_subjects WITH (security_invoker = off) AS
 SELECT r.id AS review_id,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    e.job_title,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    c.name AS cycle_name
   FROM performance_reviews r
     JOIN employees e ON e.id = r.employee_id
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN review_cycles c ON c.id = r.cycle_id
  WHERE r.reviewer_employee_id = current_user_employee();

COMMENT ON VIEW public.my_review_subjects IS
    '评估人读得到的被评估人名录:每份"我评的评估"一行。列清单就是权限边界 —— 只有名录与评估轮名,没有任何受限数据。';
