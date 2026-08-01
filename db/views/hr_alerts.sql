-- db/views/hr_alerts.sql
-- HR 待办:需要有人去处理的事,一件一行。SECURITY INVOKER。
--
-- 【只列还来得及处理的】超期 30 天以上的不再出现 —— 那已经不是"提醒"而是历史。
-- 档期:工作准证与培训 30/90 天。只含在册且未离职的员工。
--
-- 试用期三支(HR-3a):
--   probation_ending        未到期、且还没有【批准且 confirm】的试用期评估 → warning / critical
--   probation_overdue       已过期、且还没有任何已批准的决定                → expired,【不设 30 天下限】
--   probation_not_confirmed 已批准 not_confirm 但人还挂在试用期            → expired(离职仍是手工决定)
-- 【为什么 overdue 不设下限】试用期不能延长,一份没做出的转正决定不会随时间自己了结。
--
-- HR-3b 两支:
--   salary_not_set      在册(probation/active/notice)但月固定工资未录。这个数现在是承重的
--                       (假期补偿的取数来源),空着只会在离职那天才浮出来,那时已经来不及
--                       悄悄补。notice 的人给 critical:钱马上就要算了。
--                       【用 monthly_salary_set 而不是 monthly_salary IS NULL】—— 本视图是
--                       SECURITY INVOKER,引用被收回的 monthly_salary 会让整张待办视图对
--                       所有人 42501。生成列把"有没有"与"是多少"分开。
--   review_no_reviewer  非作废、未批准的评估没有评估人 —— 在开轮当天就说出来。
--
--   review_cycle_overdue 已开启的评估轮过了 due_date、仍有未提交的评估 → 每份一行
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql;
--       updated by db/migrations/2026-08-03-hr3a-performance-reviews.sql and
--       db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql.

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
 SELECT 'salary_not_set'::text AS alert_type,
        CASE
            WHEN e.employment_status = 'notice'::text THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    'Monthly fixed gross not set — leave encashment cannot be computed'::text AS subject,
    NULL::date AS due_date,
    NULL::integer AS days_remaining
   FROM employees e
  WHERE e.deleted_at IS NULL AND (e.employment_status = ANY (ARRAY['probation'::text, 'active'::text, 'notice'::text])) AND NOT e.monthly_salary_set
UNION ALL
 SELECT 'review_no_reviewer'::text AS alert_type,
    'critical'::text AS severity,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    COALESCE(c.name, 'Probation review'::text) || ' — no reviewer assigned'::text AS subject,
    c.due_date,
    c.due_date - CURRENT_DATE AS days_remaining
   FROM performance_reviews r
     JOIN employees e ON e.id = r.employee_id
     LEFT JOIN review_cycles c ON c.id = r.cycle_id
  WHERE r.reviewer_employee_id IS NULL AND (r.status <> ALL (ARRAY['approved'::text, 'acknowledged'::text, 'void'::text])) AND e.deleted_at IS NULL
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
