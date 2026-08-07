-- db/migrations/2026-08-07-hr7-accrual-respects-system-start.sql
-- HR-7:按月累积的年假要认【完整记录起始日】,与入职日、假期年起始日一次取最大。
--
-- 【缺口】accrued_annual_leave_detail 的起点是
--     GREATEST(入职当月, 本假期年 1 月 1 日)
-- —— 两个日期,就它自己而言是对的。但 finance_settings.system_start_date 不在其中:
-- 一个只从 10 月起持有完整记录的库,对 3 月入职的人照样从 3 月开始累积,
-- 把它一无所知的那七个月一起算了进去。compute_leave_encashment 再把这个余额换成钱。
-- 这正是 AGENTS.md 里那条"权利是推导的、消耗是记录的"的第四个实例:
-- 推导的那一半完美地跨过了本库不存在的时期,而记录的那一半是空的。
--
-- 【规矩,取自 HR-6 的医疗额度修复】三个日期【一次 GREATEST】,绝不逐条扣减。
-- 医疗那次就是栽在叠加上:按入职月折一次、再按起始月折一次,两步各自"正确",
-- 合起来把 3 个月折成 1 个月、300 折成 100。故障注入实测过那个数。
--
-- 【本实现结构上不会叠加,但那不是不写的理由】这里取的是【日期的最大值】,
-- 不是【月数的折扣】—— 多比较一次仍然只得到一个起点。真正危险的是改写成
-- "先算月数、再逐项扣"的形状:每一步都看得过去,而数字会安静地变小。
-- 所以判据写在函数体里,连同它为什么不能被改成扣减。
--
-- 【起始日未设置:不拒绝】HR-5 结转与 HR-6 医疗额度都抛 SYSTEM_START_NOT_SET,
-- 因为那两个是【动作】—— 拒了就停在那里,人去把设置填上。
-- 本函数是【余额】,坐在 my_profile / employees_masked 上,是员工点开 /me 就看到的
-- 那个数。因为财务少填一个设置就告诉全体员工"你的假期余额不可用",是把一个后台
-- 配置问题变成所有人的故障。所以退回两日期口径,并在返回值里如实说明
-- (system_start_applied=false),再由 hr_alerts 的 system_start_not_set 去催 ——
-- 与 holiday_calendar_missing 同一个处置:缺配置是告警,不是让功能消失。
--
-- 【下游自动继承】compute_leave_encashment 读 leave_balance → leave_balance_internal
-- → accrued_annual_leave → 本函数。它不需要、也不该有自己的一份日期逻辑。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-hr7-accrual-respects-system-start.sql

BEGIN;

CREATE OR REPLACE FUNCTION public.accrued_annual_leave_detail(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp      record;
    v_year     integer := EXTRACT(YEAR FROM p_as_of)::integer;
    v_asof     date;
    v_first    date;
    v_last     date;
    v_m        date;
    v_cat      text;
    v_rate     jsonb;
    v_dpy_sum  numeric := 0;
    v_raw      numeric := 0;
    v_months   jsonb := '[]'::jsonb;
    v_sys      date;        -- HR-7:完整记录起始日(finance_settings.system_start_date)
    v_sys_used boolean;
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    SELECT id, code, hire_date, work_category, employment_status, separation_date
    INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    -- 【离职冻结】最后在职日之后不再累积
    v_asof := p_as_of;
    IF v_emp.separation_date IS NOT NULL AND v_emp.separation_date < v_asof THEN
        v_asof := v_emp.separation_date;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- HR-7:【三个日期一次 GREATEST,不做叠加扣减】
    -- 累积的起点是三件事的【交集】:这个人什么时候入职、这个假期年从哪天开始、
    -- 本库从哪天起持有完整记录。取三者之中最晚的那一个 —— 一次比较,得一个日期。
    --
    -- 【为什么必须是 GREATEST 而不是逐条扣减】HR-6 的医疗额度就是这么栽的:
    -- 先按入职月折一次、再按起始月折一次,两次都"对",合起来把 3 个月折成了
    -- 1 个月、300 折成 100。这里的实现是【日期取最大】而不是【月数打折】,
    -- 结构上就不会叠加 —— 但那正是要写下来的理由:换成"先算月数再逐项扣"的
    -- 写法,数字会安静地变小,而每一步看起来都成立。
    --
    -- 【起始日所在的那个月算进去】与 medical_claim_balance 同口径
    -- (它取 EXTRACT(MONTH FROM v_start),即含起始月)。
    --
    -- 【起始日未设置时不拒绝】HR-5 的结转与 HR-6 的医疗额度都抛
    -- SYSTEM_START_NOT_SET —— 那两个是【动作】(结转、批报销),拒了就停在那里。
    -- 本函数是【余额】:它坐在 my_profile / employees_masked 上,是员工点开
    -- /me 就会看到的那个数。因为财务的一个设置没填而告诉全体员工"你的假期余额
    -- 不可用",是把一个后台配置问题变成所有人的故障。
    -- 所以这里【退回两日期口径】并在返回值里说明,由 hr_alerts 的
    -- system_start_not_set 去催那个设置(同 holiday_calendar_missing 的处置:
    -- 缺配置是告警,不是让功能消失)。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT system_start_date INTO v_sys FROM finance_settings LIMIT 1;
    v_sys_used := v_sys IS NOT NULL;

    v_first := GREATEST(date_trunc('month', v_emp.hire_date)::date, make_date(v_year, 1, 1));
    IF v_sys_used THEN
        v_first := GREATEST(v_first, date_trunc('month', v_sys)::date);
    END IF;
    v_last  := LEAST((date_trunc('month', v_asof + 1) - interval '1 month')::date,
                     make_date(v_year, 12, 1));

    IF v_asof < make_date(v_year, 1, 1) OR v_last < v_first THEN
        RETURN jsonb_build_object(
            'employee_id', p_employee_id, 'employee_code', v_emp.code,
            'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
            'months', '[]'::jsonb, 'months_accrued', 0, 'raw_days', 0, 'accrued_days', 0,
            'system_start_date', v_sys, 'system_start_applied', v_sys_used,
            'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
    END IF;

    v_m := v_first;
    WHILE v_m <= v_last LOOP
        v_cat  := employee_work_category_at(p_employee_id, v_m);
        v_rate := leave_accrual_rate(p_employee_id, v_cat, v_m);
        -- 【只累加年额,不在这里除】Σ区间(年额 × 月数/12) 与 (Σ每月年额)/12 是同一个数,
        -- 但后者中间不产生任何除不尽的小数 —— 25/12 那种数字永远不会出现在中间结果里。
        v_dpy_sum := v_dpy_sum + (v_rate->>'days_per_year')::numeric;
        v_months := v_months || jsonb_build_object(
            'month', to_char(v_m, 'YYYY-MM'),
            'work_category', v_cat,
            'days_per_year', (v_rate->>'days_per_year')::numeric,
            'rate_source', v_rate->>'source',
            'rate_effective_from', v_rate->>'effective_from');
        v_m := (v_m + interval '1 month')::date;
    END LOOP;

    v_raw := v_dpy_sum / 12;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code,
        'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
        'first_month', to_char(v_first, 'YYYY-MM'), 'last_complete_month', to_char(v_last, 'YYYY-MM'),
        -- 起点由哪三个日期定的,以及第三个到底有没有生效 —— 看得见才查得动
        'system_start_date', v_sys, 'system_start_applied', v_sys_used,
        'months', v_months,
        'months_accrued', jsonb_array_length(v_months),
        'sum_of_annual_rates', v_dpy_sum,
        'raw_days', trim_scale(v_raw),
        -- 【向下取到 0.5 天只作用于总数】,不再逐月作用 —— 那正是 24.9996 的来处。
        'accrued_days', trim_scale(floor(v_raw * 2) / 2),
        'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
END;
$function$
;
-- hr_alerts:少了这个设置要有人被喊 —— 同 holiday_calendar_missing 的形状
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
          WHERE s.system_start_date IS NOT NULL));

COMMIT;
