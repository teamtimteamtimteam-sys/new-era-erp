-- db/views/hr_alerts.sql
-- HR 待办:需要有人去处理的事,一件一行。【属主权限】(OPS-14 起)。
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
--                       (当时是 SECURITY INVOKER)引用被收回的 monthly_salary 会让整张待办视图对
--                       所有人 42501。生成列把"有没有"与"是多少"分开。
--   review_no_reviewer  非作废、未批准的评估没有评估人 —— 在开轮当天就说出来。
--
--   review_cycle_overdue 已开启的评估轮过了 due_date、仍有未提交的评估 → 每份一行
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql;
--       updated by db/migrations/2026-08-03-hr3a-performance-reviews.sql and
--       db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql.
--
-- HR-7(2026-08-07):system_start_not_set —— finance_settings.system_start_date 为空。
-- 按月累积因此退回"入职 / 年初"两日期口径(accrued_annual_leave_detail 不拒绝:
-- 余额坐在 /me 上,不能因为财务少填一个设置就对全体员工消失),所以【必须有人被催】。
-- 与 holiday_calendar_missing 同一处置:缺配置是告警,不是让功能消失。
--
-- HR-4(2026-08-05):假日表告警分两支两级 ——
--   holiday_calendar_missing    当年一条都没有 → expired,任何月份(全新安装的处境);
--   holiday_calendar_next_year  次年没有 → 10 月起 warning、12 月 critical(原行为)。
-- 旧版只查次年、只在四季度,盲区恰好是它唯一该守住的时刻。
-- 不加"条数下限"的理由见迁移文件头(country 列已在,写死新加坡的条数是辖区常量)。

-- OPS-14(2026-08-08):改为【属主权限】+ module.hr.view 写在外层。
-- system_start_not_set 那支读 finance_settings(挂 module.finance.view),写法是
-- NOT EXISTS(...)。原先 invoker 时 RLS 让行消失 → NOT EXISTS 恒真 →【日期明明填了,
-- hr 角色却永远看见这条告警】,而且他清不掉,因为驱动它的表他读不到。
-- 行消失在这里制造【假阳性】,与 allocation_status 的假阴性相反 —— 同一个病两个方向。
-- 谓词写在外层而不是逐支重复:12 支的可见性是同一个,复述 12 遍只会给下一个加支的人
-- 留一个漏写的机会。
-- 【放弃了什么】原先 employees 的 "select own row" 策略让零 HR 权限的员工能读到关于
-- 自己的那几支。全库没有页面这么用(只有 /hr 与 /hr/training 读它,都在 HR 模块内),
-- 自助侧走 my_profile / my_leave_balance / my_review_subjects。故无损失,记此备查。

CREATE VIEW public.hr_alerts WITH (security_invoker = off) AS
 SELECT a.alert_type, a.severity, a.employee_id, a.employee_code, a.employee_name,
        a.subject, a.due_date, a.days_remaining
 FROM (
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
 SELECT 'cpf_due'::text AS alert_type,
        CASE
            WHEN (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date < CURRENT_DATE THEN 'expired'::text
            WHEN ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 3 THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    NULL::uuid AS employee_id,
    p.code AS employee_code,
    'CPF'::text AS employee_name,
    'CPF contribution unpaid — due 14th of the following month, late payment attracts interest'::text AS subject,
    (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date AS due_date,
    (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE AS days_remaining
   FROM payroll_periods p
  WHERE p.deleted_at IS NULL AND p.status = 'posted'::text AND p.cpf_paid_at IS NULL AND (COALESCE(p.employer_cpf_total, 0::numeric) + COALESCE(p.employee_cpf_total, 0::numeric)) > 0::numeric AND ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 7
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
  WHERE t.deleted_at IS NULL AND e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND t.expiry_date IS NOT NULL AND (t.expiry_date - CURRENT_DATE) <= 90 AND (t.expiry_date - CURRENT_DATE) >= '-30'::integer
UNION ALL
 SELECT 'holiday_calendar_missing'::text AS alert_type,
    'expired'::text AS severity,
    NULL::uuid AS employee_id,
    ''::text AS employee_code,
    ''::text AS employee_name,
    EXTRACT(year FROM CURRENT_DATE)::text AS subject,
    CURRENT_DATE AS due_date,
    0 AS days_remaining
  WHERE NOT (EXISTS ( SELECT 1
           FROM public_holidays h
          WHERE h.is_active AND h.country = 'SG'::text AND EXTRACT(year FROM h.holiday_date) = EXTRACT(year FROM CURRENT_DATE)))
UNION ALL
 SELECT 'holiday_calendar_next_year'::text AS alert_type,
        CASE
            WHEN EXTRACT(month FROM CURRENT_DATE) = 12::numeric THEN 'critical'::text
            ELSE 'warning'::text
        END AS severity,
    NULL::uuid AS employee_id,
    ''::text AS employee_code,
    ''::text AS employee_name,
    (EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::text AS subject,
    make_date((EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::integer, 1, 1) AS due_date,
    make_date((EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::integer, 1, 1) - CURRENT_DATE AS days_remaining
  WHERE EXTRACT(month FROM CURRENT_DATE) >= 10::numeric AND NOT (EXISTS ( SELECT 1
           FROM public_holidays h
          WHERE h.is_active AND h.country = 'SG'::text AND EXTRACT(year FROM h.holiday_date) = (EXTRACT(year FROM CURRENT_DATE) + 1::numeric)))
UNION ALL
 SELECT 'system_start_not_set'::text AS alert_type,
    'expired'::text AS severity,
    NULL::uuid AS employee_id,
    ''::text AS employee_code,
    ''::text AS employee_name,
    ''::text AS subject,
    CURRENT_DATE AS due_date,
    0 AS days_remaining
  WHERE NOT (EXISTS ( SELECT 1
           FROM finance_settings s
          WHERE s.system_start_date IS NOT NULL))
 ) a
 WHERE has_permission('module.hr.view'::text);
