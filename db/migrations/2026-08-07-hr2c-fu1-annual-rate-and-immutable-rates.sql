-- db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql
-- HR-2c 跟进 1:费率行生效即不可改;费率存【年额】,月额是算出来的。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【一、生效了的费率行不能再改】
-- HR-2c 的 B3 保证"改费率之前的月份保留旧费率"。但那条保证目前【只靠没有人去改历史】:
-- 一条 UPDATE 就能把某个员工从入职日到今天的每一个月重算一遍 —— 没有痕迹、没有留档,
-- 而且 check_mirrors 也照不到,因为 leave_accrual_rates 是【运行期配置】、【刻意】不做
-- 逐行比对。于是这里补上与 employment_history、accounts.is_system 同一种保护:
--   * effective_from <= 今天 的行:UPDATE 与 DELETE 一律拒绝。
--     改费率 = 插一条更晚生效的新行;更正一条写错的历史行 = 同样是插入,不是编辑。
--   * 【未来生效的行仍然可改】它还没影响过任何人的余额,改它不会重写任何历史。
--
-- 【二、存年额,月额算出来】
-- 原来存的是"每月天数"。一份写着 25 天/年的合同要填 2.0833,十二个月加起来是
-- 24.9996,向下取到 0.5 就变成 24.5 —— 合同写 25 的人只能请 24.5 天。
-- 24 与 18 恰好能被 12 整除,所以标准档看不出这个问题;而 override 这个功能
-- 存在的意义,恰恰就是那些除不尽的数字。
--
-- 改成存 days_per_year,累积按【费率区间】求和:
--     Σ 各区间( days_per_year × 该区间月数 / 12 )
-- 实现上等价于"先把每个月适用的年额加起来,最后【只除一次】12" —— 线性求和,
-- 结果完全相同,而且中间不产生任何一个除不尽的小数。
--     25 天/年满一年   = (25 × 12) / 12 = 25.0     (原来是 24.9996)
--     18 半年 + 24 半年 = (18×6 + 24×6) / 12 = 21.0 (与 HR-2c 完全一致)
-- 向下取到 0.5 天的规则【只作用于总数】,不再逐月作用。
--
-- 【三、顺手】leave_types 的说明里还写着 employees.annual_leave_days(已删的列)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 二、年额 ────────────────────────────────────────────────────────────────
ALTER TABLE public.leave_accrual_rates RENAME COLUMN days_per_month TO days_per_year;

ALTER TABLE public.leave_accrual_rates
    DROP CONSTRAINT leave_accrual_rates_days_per_month_check;
ALTER TABLE public.leave_accrual_rates
    ADD CONSTRAINT leave_accrual_rates_days_non_negative
        CHECK (days_per_year IS NULL OR days_per_year >= 0);

-- 种子换算回年额。【必须在不可改触发器建立之前做】—— 之后它自己也改不动了。
UPDATE public.leave_accrual_rates SET days_per_year = 24 WHERE work_category = 'office';
UPDATE public.leave_accrual_rates SET days_per_year = 18 WHERE work_category = 'shopfloor';

COMMENT ON COLUMN public.leave_accrual_rates.days_per_year IS
    '【年额】,不是月额。累积按 Σ(年额 × 区间月数 / 12) 算,最后只除一次 12 —— '
    '存月额的话,25 天/年要写 2.0833,十二个月加起来 24.9996,向下取整后合同写 25 的人只能请 24.5。'
    '员工行为 NULL 表示"从 effective_from 起回到类别费率"。类别行不许为 NULL。';

-- ── 解析器:返回年额 ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.leave_accrual_rate(p_employee_id uuid, p_work_category text, p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_days numeric;
    v_from date;
BEGIN
    SELECT r.days_per_year, r.effective_from INTO v_days, v_from
    FROM leave_accrual_rates r
    WHERE r.employee_id = p_employee_id AND r.effective_from <= p_month
    ORDER BY r.effective_from DESC
    LIMIT 1;

    IF v_days IS NOT NULL THEN
        RETURN jsonb_build_object('days_per_year', v_days, 'source', 'override',
                                  'effective_from', v_from);
    END IF;

    SELECT r.days_per_year, r.effective_from INTO v_days, v_from
    FROM leave_accrual_rates r
    WHERE r.work_category = p_work_category AND r.effective_from <= p_month
    ORDER BY r.effective_from DESC
    LIMIT 1;

    IF v_days IS NULL THEN
        RETURN jsonb_build_object('days_per_year', 0, 'source', 'none', 'effective_from', NULL);
    END IF;
    RETURN jsonb_build_object('days_per_year', v_days, 'source', 'category',
                              'effective_from', v_from);
END;
$function$;

-- ── 累积:先把每月适用的年额加起来,最后只除一次 12 ─────────────────────────
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
BEGIN
    SELECT id, code, hire_date, work_category, employment_status, separation_date
    INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    -- 【离职冻结】最后在职日之后不再累积
    v_asof := p_as_of;
    IF v_emp.separation_date IS NOT NULL AND v_emp.separation_date < v_asof THEN
        v_asof := v_emp.separation_date;
    END IF;

    v_first := GREATEST(date_trunc('month', v_emp.hire_date)::date, make_date(v_year, 1, 1));
    v_last  := LEAST((date_trunc('month', v_asof + 1) - interval '1 month')::date,
                     make_date(v_year, 12, 1));

    IF v_asof < make_date(v_year, 1, 1) OR v_last < v_first THEN
        RETURN jsonb_build_object(
            'employee_id', p_employee_id, 'employee_code', v_emp.code,
            'leave_year', v_year, 'as_of', p_as_of, 'effective_as_of', v_asof,
            'months', '[]'::jsonb, 'months_accrued', 0, 'raw_days', 0, 'accrued_days', 0,
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
        'months', v_months,
        'months_accrued', jsonb_array_length(v_months),
        'sum_of_annual_rates', v_dpy_sum,
        'raw_days', trim_scale(v_raw),
        -- 【向下取到 0.5 天只作用于总数】,不再逐月作用 —— 那正是 24.9996 的来处。
        'accrued_days', trim_scale(floor(v_raw * 2) / 2),
        'frozen_at_separation', v_emp.separation_date IS NOT NULL AND v_emp.separation_date < p_as_of);
END;
$function$;

-- ── 视图用的年度费率:直接就是年额 ──────────────────────────────────────────
DROP VIEW public.employee_directory;
DROP VIEW public.my_profile;
DROP VIEW public.employees_masked;
DROP FUNCTION public.annual_leave_rate_per_month(uuid, date);

CREATE OR REPLACE FUNCTION public.annual_leave_rate_per_year(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT (leave_accrual_rate(
                p_employee_id,
                employee_work_category_at(p_employee_id, date_trunc('month', p_as_of)::date),
                date_trunc('month', p_as_of)::date
            )->>'days_per_year')::numeric;
$function$;

CREATE VIEW public.employees_masked WITH (security_invoker = off) AS
 SELECT id, code, legal_name, preferred_name, department_id, job_title, manager_id,
    employment_type, work_category, hire_date, probation_end_date, employment_status,
    separation_date, separation_type, separation_notes,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_email
            ELSE NULL::text
        END AS work_email,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_phone
            ELSE NULL::text
        END AS work_phone,
    residency_status,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN identity_no
            ELSE NULL::text
        END AS identity_no,
    work_pass_type,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_pass_no
            ELSE NULL::text
        END AS work_pass_no,
    work_pass_issue_date, work_pass_expiry_date, user_id, notes, deleted_at,
    created_at, created_by, updated_at, updated_by, confirmation_date,
        CASE
            WHEN has_permission('data.view_pay'::text) OR id = current_user_employee() THEN monthly_salary
            ELSE NULL::numeric
        END AS monthly_salary,
    monthly_salary_set, review_exempt,
    CASE WHEN deleted_at IS NULL THEN annual_leave_rate_per_year(id) END AS annual_leave_rate_days,
    CASE WHEN deleted_at IS NULL THEN accrued_annual_leave(id) END AS annual_leave_accrued_days,
    CASE WHEN deleted_at IS NULL
         THEN (leave_balance_internal(id, 'annual'::text)->>'available')::numeric END AS annual_leave_available_days
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();

CREATE VIEW public.my_profile WITH (security_invoker = off) AS
 SELECT e.id AS employee_id, e.code, e.legal_name, e.preferred_name, e.job_title,
    e.employment_type, e.work_category, e.employment_status, e.hire_date, e.probation_end_date,
    annual_leave_rate_per_year(e.id) AS annual_leave_rate_days,
    accrued_annual_leave(e.id) AS annual_leave_accrued_days,
    (leave_balance_internal(e.id, 'annual'::text)->>'available')::numeric AS annual_leave_available_days,
    e.residency_status, e.work_pass_type, e.work_pass_no, e.work_pass_issue_date,
    e.work_pass_expiry_date, e.identity_no, e.work_email, e.work_phone,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    mgr.legal_name AS manager_name,
    mgr.code AS manager_code,
    COALESCE(tr.cnt, 0::bigint) AS training_count,
    pp.code AS latest_payroll_code,
    pp.period_month AS latest_payroll_month
   FROM employees e
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT count(*) AS cnt
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
     LEFT JOIN LATERAL ( SELECT p.code,
            p.period_month
           FROM payroll_lines pl
             JOIN payroll_periods p ON p.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND p.status = 'posted'::text AND p.deleted_at IS NULL
          ORDER BY p.period_month DESC
         LIMIT 1) pp ON true
  WHERE e.id = current_user_employee() AND e.deleted_at IS NULL;

CREATE VIEW public.employee_directory WITH (security_invoker = on) AS
 SELECT e.id AS employee_id, e.code, e.legal_name, e.preferred_name, e.department_id,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    e.job_title, e.manager_id,
    mgr.code AS manager_code,
    mgr.legal_name AS manager_name,
    e.employment_type, e.work_category, e.employment_status, e.hire_date, e.probation_end_date,
    e.annual_leave_rate_days,
    e.annual_leave_accrued_days,
    e.annual_leave_available_days,
    e.residency_status, e.work_pass_type, e.work_pass_expiry_date,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::integer
            ELSE e.work_pass_expiry_date - CURRENT_DATE
        END AS days_to_work_pass_expiry,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::text
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 90 THEN 'warning'::text
            ELSE NULL::text
        END AS work_pass_alert,
    pay.gross_pay AS current_gross_pay,
    pay.period_month AS current_pay_period,
    COALESCE(tr.training_count, 0::bigint) AS training_count
   FROM employees_masked e
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees_masked mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT pl.gross_pay,
            pp.period_month
           FROM payroll_lines_masked pl
             JOIN payroll_periods pp ON pp.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND pp.status = 'posted'::text AND pp.deleted_at IS NULL
          ORDER BY pp.period_month DESC
         LIMIT 1) pay ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS training_count
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
  WHERE e.deleted_at IS NULL;

-- ── 一、生效即不可改 ────────────────────────────────────────────────────────
-- 【为什么是触发器而不是策略】RLS 管的是"谁能改",这里要管的是"这一行还能不能改"——
-- 与 employment_history 的不可变守卫、accounts 的 is_system 守卫是同一类保护。
CREATE OR REPLACE FUNCTION public.guard_effective_accrual_rate()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.effective_from <= CURRENT_DATE THEN
            RAISE EXCEPTION 'RATE_IN_EFFECT_IMMUTABLE|%', OLD.effective_from;
        END IF;
        RETURN OLD;
    END IF;
    -- 【未来生效的行仍可改】它还没影响过任何人的余额。
    IF OLD.effective_from <= CURRENT_DATE THEN
        RAISE EXCEPTION 'RATE_IN_EFFECT_IMMUTABLE|%', OLD.effective_from;
    END IF;
    RETURN NEW;
END;
$fn$;

-- 名字里的 immutable 排在 updated_at 之前,所以拒绝发生在盖时间戳之前
CREATE TRIGGER trg_leave_accrual_rates_immutable
    BEFORE UPDATE OR DELETE ON public.leave_accrual_rates
    FOR EACH ROW EXECUTE FUNCTION public.guard_effective_accrual_rate();

-- ── 三、leave_types 的说明还指着一列已经删掉的字段 ──────────────────────────
UPDATE public.leave_types
SET description_en = 'Paid annual leave. Earned monthly; the rate comes from leave_accrual_rates, not this table.',
    description_zh = '带薪年假。按月累积;费率取自 leave_accrual_rates,不取自本表。',
    notes = 'Entitlement source: leave_accrual_rates (office 24 / shopfloor 18 days per year, accrued monthly). '
            'Statutory minimum under the Employment Act is 7 days rising to 14 with service — the company figure is well above it.'
WHERE code = 'annual';

COMMIT;
