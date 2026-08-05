-- HR-4:假日表告警 —— 当年缺,立刻报;次年缺,四季度报。
--
-- 【为什么改】原告警只在 10 月起检查【次年】。于是 2026 年之后做的全新安装
-- (引导数据只播了 2026 的假日)会是这样:
--   2027 年 3 月装库 → 当年一条假日都没有 → 请假天数把每个公共假日算成工作日,
--   【静默】算错;而告警到 10 月才开口,说的还是 2028 年。
-- 也就是说,这个守卫的盲区恰好就是【全新安装】—— 它唯一真正需要被守住的时刻。
--
-- 现在两支两级:
--   holiday_calendar_missing     当年没有 → expired,任何月份,立刻;
--   holiday_calendar_next_year   次年没有 → 10 月起 warning,12 月 critical(原行为)。
--
-- 【为什么不加"条数下限"】(评估过,决定不加)
-- 想法是:存在性检查过不了"录了 4 条就算录过"这一关,不如要求至少 N 条。
-- 不加的理由有两条,第二条是决定性的:
--   1. 假一致数并不固定 —— 新加坡宪报公布 11 个假日,但落在周日的会顺延出一条,
--      所以行数在 11–14 之间浮动(本仓库 2026 年的引导数据就是 14 行)。
--      任何阈值要么误报,要么松到抓不住 10 缺 1。
--   2. 【country 列已经在那儿了】。这张表从一开始就是按多国设计的,把新加坡的
--      假日条数写死进检查,就是刚花一整个切次从代码里清掉的那类"辖区常量"
--      (见 AGENTS.md 的币种字面量规则)。加了它,第二个国家上线当天它就是错的。
-- 机器能验的是"有没有",不能验"全不全";"全不全"写进 docs/fresh-install-checklist.md
-- 交给人 —— 把边界说清楚,好过用一个假的精确度盖住它。

BEGIN;

CREATE OR REPLACE VIEW public.hr_alerts WITH (security_invoker = on) AS
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
-- 【当年缺假日 —— 立刻,任何月份】这一支是给【全新安装】的。
-- 引导数据只播了 2026 年的假日,而假日表是承重的:calculate_leave_days 用它算
-- 请假天数、fx_rate_asof 用它判断哪天不发布牌价。2026 年之后做的全新安装会得到
-- 一张只有 2026 的表 —— 当年的每个公共假日都被当成工作日,请假天数【静默】算错。
-- 旧版只在 10 月起检查【次年】,于是 2027 年 3 月装的库整年没有任何提示。
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
          WHERE h.is_active AND h.country = 'SG'::text
            AND EXTRACT(year FROM h.holiday_date) = EXTRACT(year FROM CURRENT_DATE)))
UNION ALL
-- 【次年缺假日 —— 第四季度起提醒】原有行为,不变:年底前把明年的排进来。
 SELECT 'holiday_calendar_next_year'::text AS alert_type,
    CASE WHEN EXTRACT(month FROM CURRENT_DATE) = 12 THEN 'critical'::text
         ELSE 'warning'::text END AS severity,
    NULL::uuid AS employee_id,
    ''::text AS employee_code,
    ''::text AS employee_name,
    (EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::text AS subject,
    make_date((EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::integer, 1, 1) AS due_date,
    make_date((EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::integer, 1, 1) - CURRENT_DATE AS days_remaining
  WHERE EXTRACT(month FROM CURRENT_DATE) >= 10::numeric
    AND NOT (EXISTS ( SELECT 1
           FROM public_holidays h
          WHERE h.is_active AND h.country = 'SG'::text
            AND EXTRACT(year FROM h.holiday_date) = (EXTRACT(year FROM CURRENT_DATE) + 1::numeric)));

COMMIT;
