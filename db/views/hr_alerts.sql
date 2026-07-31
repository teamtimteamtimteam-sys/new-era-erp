-- db/views/hr_alerts.sql
-- HR 待办:需要有人去处理的事,一件一行(工作准证到期 / 试用期届满 / 培训证书到期)。
--
-- 【只列还来得及处理的】超期 30 天以上的不再出现 —— 那已经不是"提醒"而是历史,
-- 留在清单里只会把真正紧急的几条淹掉;要查历史去各自的明细表。
-- 档期:工作准证与培训 30/90 天;试用期 14/30 天(试用期本来就短)。
-- 只含在册且未离职的员工。SECURITY INVOKER。
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql.

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
            WHEN e.probation_end_date < CURRENT_DATE THEN 'expired'::text
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
  WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND (e.probation_end_date - CURRENT_DATE) <= 30 AND (e.probation_end_date - CURRENT_DATE) >= '-30'::integer
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
