-- db/views/hr_alerts.sql
-- HR 待办:需要有人去处理的事,一件一行。
--
-- 【只列还来得及处理的】超期 30 天以上的不再出现 —— 那已经不是"提醒"而是历史,
-- 留在清单里只会把真正紧急的几条淹掉;要查历史去各自的明细表。
-- 档期:工作准证与培训 30/90 天。只含在册且未离职的员工。SECURITY INVOKER。
--
-- 【HR-3a 把试用期那一支拆成三支】,因为"试用期不能延长"改变了什么该留在看板上:
--   probation_ending        还没到期、且还没有【批准且 confirm】的试用期评估 → warning / critical
--   probation_overdue       已过期、且还没有任何已批准的决定                  → expired,【不设 30 天下限】
--   probation_not_confirmed 已批准 not_confirm 但人还挂在试用期              → expired(离职仍是手工决定)
-- 【为什么 overdue 不设下限】原来的 -30 天下限是"过期太久就不再是提醒而是历史"。
-- 那条理由对工作准证成立,对试用期【不成立】—— 试用期不能延长,一份没做出的
-- 转正决定不会随时间自己了结,它只会一直欠着;让它从看板上消失等于把唯一会
-- 提醒人的东西关掉。
--   review_cycle_overdue    已开启的评估轮过了 due_date、仍有未提交的评估    → 每份一行
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql;
--       updated by db/migrations/2026-08-03-hr3a-performance-reviews.sql.

CREATE OR REPLACE VIEW public.hr_alerts
WITH (security_invoker = on) AS
 SELECT 'work_pass_expiry'::text AS alert_type,
        CASE
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(e.work_pass_type, 'Work pass'::text) AS subject,
    e.work_pass_expiry_date AS due_date,
    e.work_pass_expiry_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND e.work_pass_expiry_date IS NOT NULL AND (e.work_pass_expiry_date - CURRENT_DATE) <= 90 AND (e.work_pass_expiry_date - CURRENT_DATE) >= '-30'::integer
UNION ALL
 SELECT 'probation_ending'::text AS alert_type,
        CASE
            WHEN (e.probation_end_date - CURRENT_DATE) <= 14 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation'::text AS subject,
    e.probation_end_date AS due_date,
    e.probation_end_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date >= CURRENT_DATE AND (e.probation_end_date - CURRENT_DATE) <= 30 AND NOT (EXISTS ( SELECT 1
           FROM performance_reviews r
          WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'confirm'::text))
UNION ALL
 SELECT 'probation_overdue'::text AS alert_type,
    'expired'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation ended without a decision'::text AS subject,
    e.probation_end_date AS due_date,
    e.probation_end_date - CURRENT_DATE AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
           FROM performance_reviews r
          WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome IS NOT NULL))
UNION ALL
 SELECT 'probation_not_confirmed'::text AS alert_type,
    'expired'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Probation not confirmed — separation is a manual decision'::text AS subject,
    COALESCE(e.probation_end_date, r.approved_at::date) AS due_date,
    COALESCE(e.probation_end_date, r.approved_at::date) - CURRENT_DATE AS days_remaining
   FROM employees e
     JOIN performance_reviews r ON r.employee_id = e.id
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'not_confirm'::text
UNION ALL
 SELECT 'review_cycle_overdue'::text AS alert_type,
    'critical'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    c.name AS subject,
    c.due_date,
    c.due_date - CURRENT_DATE AS days_remaining
   FROM performance_reviews r
     JOIN review_cycles c ON c.id = r.cycle_id
     JOIN employees e ON e.id = r.employee_id
  WHERE c.deleted_at IS NULL AND c.status = 'open'::text AND c.due_date < CURRENT_DATE AND (r.status = ANY (ARRAY['draft'::text, 'self_review'::text]))
UNION ALL
 SELECT 'training_expiry'::text AS alert_type,
        CASE
            WHEN t.expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (t.expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    t.training_name AS subject,
    t.expiry_date AS due_date,
    t.expiry_date - CURRENT_DATE AS days_remaining
   FROM training_records t
     JOIN employees e ON e.id = t.employee_id
  WHERE t.deleted_at IS NULL AND e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND t.expiry_date IS NOT NULL AND (t.expiry_date - CURRENT_DATE) <= 90 AND (t.expiry_date - CURRENT_DATE) >= '-30'::integer;
