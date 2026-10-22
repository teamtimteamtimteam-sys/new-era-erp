-- db/functions/leave_service_entitlement.sql
-- PAYROLL-PAY-REVERSAL-1 · B1(Tim 2026-10-22,Step 0 Q10 · Q11):一个按年额度的假别,对【服务了这么久】的人,这一年给多少天。
--
--   服务期 = 从 hire_date 到 p_as_of(请假的开始日;余额页上是今天)之间【完整的月数】,不满一个月的那一截不算(Q10):
--     age(p_as_of, hire_date) 的 年 × 12 + 月。1 月 31 日入职、2 月 28 日请 —— 0 个月。
--   规矩全是 leave_types 上的列(Q11:配置,不是写死的假别码):
--     qualifying_service_months   不满这么多个完整的月 → 0 天;
--     service_rule = 'full'       满了就是 default_days_per_year 整年(产假 · 陪产假 · 共享育儿假 · 婴儿看护假:3 个月;
--                                 婚假 · 恩恤假 · 考试假:0 个月,公司政策);
--     service_rule = 'steps'      满了按 service_steps 的台阶给:{"3": 5, "4": 8, "5": 11} = 第 3 / 4 / 5 个完整月各给几天,
--                                 过了最高一级台阶 → default_days_per_year(门诊病假 5 / 8 / 11 → 14;住院假 15 / 30 / 45 → 60,MOM 的表);
--     service_rule = 'prorate_first_year'  服务不满 12 个完整月时按月折算:
--                                 default_days_per_year × 完整月数 ÷ 12,四舍五入到整天(半天进位:floor(x + 0.5)),
--                                 再不少于 prorate_minimum_days(育儿假 2 天,Tim 加的);满 12 个月 → 整年。
--   p_hire_date 为 NULL(不会发生:employees.hire_date NOT NULL)按 0 个月算。
--   【INVOKER,不问码】只读 leave_types(人人可读的目录);只在 leave_balance_internal(DEFINER)里被调。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.leave_service_entitlement(p_leave_type_code text, p_hire_date date, p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t      leave_types%ROWTYPE;
    v_months integer := 0;
    v_days   numeric;
    v_step   integer;
BEGIN
    SELECT * INTO v_t FROM leave_types WHERE code = p_leave_type_code;
    IF NOT FOUND OR v_t.default_days_per_year IS NULL THEN
        RETURN jsonb_build_object('days', NULL, 'service_months', NULL, 'rule', NULL);
    END IF;
    IF p_hire_date IS NOT NULL AND p_as_of >= p_hire_date THEN
        v_months := (EXTRACT(YEAR FROM age(p_as_of, p_hire_date)) * 12 + EXTRACT(MONTH FROM age(p_as_of, p_hire_date)))::integer;
    END IF;

    IF v_months < v_t.qualifying_service_months THEN
        v_days := 0;
    ELSIF v_t.service_rule = 'steps' THEN
        SELECT max(k::integer) INTO v_step
          FROM jsonb_object_keys(v_t.service_steps) k
         WHERE k::integer <= v_months;
        IF v_step IS NULL THEN
            v_days := 0;
        ELSIF v_months > (SELECT max(k::integer) FROM jsonb_object_keys(v_t.service_steps) k) THEN
            v_days := v_t.default_days_per_year;
        ELSE
            v_days := (v_t.service_steps ->> v_step::text)::numeric;
        END IF;
    ELSIF v_t.service_rule = 'prorate_first_year' AND v_months < 12 THEN
        v_days := GREATEST(floor(v_t.default_days_per_year * v_months / 12.0 + 0.5),
                           COALESCE(v_t.prorate_minimum_days, 0));
    ELSE
        v_days := v_t.default_days_per_year;
    END IF;

    RETURN jsonb_build_object('days', trim_scale(v_days), 'service_months', v_months, 'rule', v_t.service_rule,
                              'qualifying_months', v_t.qualifying_service_months,
                              'full_days', v_t.default_days_per_year);
END;
$function$;
