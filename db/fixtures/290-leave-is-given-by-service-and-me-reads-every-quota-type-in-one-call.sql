-- fixture 290 —— 假按服务期给;/me 一次调用读出每一种有额度的假(PAYROLL-PAY-REVERSAL-1 · B1 · B2,2026-10-22)
--
-- Tim 2026-10-22 的裁定(Step 0 Q10 · Q11 · Q12):服务期 = hire_date 到请假开始日之间【完整的月数】,不满一个月的那一截不算;
-- 规矩全是 leave_types 上的列(本支先断言引导值就是裁定,再用它们):
--   门诊病假 / 住院假:不满 3 个月 0;第 3 / 4 / 5 个完整月 5 / 8 / 11 · 15 / 30 / 45;第 6 个月起 14 / 60(MOM 的表)
--   育儿假 / 延长育儿假:不满 3 个月 0;不满 12 个月按月折算(× 月数 ÷ 12,四舍五入到整天,半天进位),育儿假至少 2 天
--   产假 / 陪产假 / 共享育儿假 / 婴儿看护假:不满 3 个月 0,之后整年;婚假 / 恩恤假 / 考试假:没有资格期
-- 各臂:
--   A  引导值 = 裁定(leave_types 那四列逐字)
--   B  算式(leave_service_entitlement),逐个月份 —— 每一个数在右边写着它怎么来的;B2 折算下限那一列确实起作用
--   C  完整的月:1 月 31 日入职,2 月 28 日 = 0 个月;3 月 31 日 = 2 个月
--   D  余额与提交:入职 2 个月的人病假 available = 0,提交一天病假按名拒 INSUFFICIENT_BALANCE;入职 4 个月的 = 8,提得上
--   E  /me:leave_balances 一次回 12 种(含年假、不含无薪假),按 sort_order;本人读得到,别人(没有 hr.view)按名拒
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.f290_days(p_type text, p_hire date, p_as_of date) RETURNS numeric
LANGUAGE sql AS $f$ SELECT (leave_service_entitlement(p_type, p_hire, p_as_of) ->> 'days')::numeric $f$;

DO $$
DECLARE
    u_new uuid := gen_random_uuid();   -- 入职 2 个月
    u_mid uuid := gen_random_uuid();   -- 入职 4 个月
    u_out uuid := gen_random_uuid();   -- 另一个员工,没有任何码
    e_new uuid := gen_random_uuid(); e_mid uuid := gen_random_uuid(); e_out uuid := gen_random_uuid();
    d0 date := DATE '2025-01-06';      -- 一个周一;所有日子从它往后数
    v_msg text; v_bal jsonb; v_all jsonb; v_codes text; v_got numeric; c record;
BEGIN
    -- ══════════ A · 引导值 = 裁定 ═══════════════════════════════════════════
    SELECT string_agg(code || ':' || qualifying_service_months || ':' || service_rule || ':' || COALESCE(service_steps::text, '-')
                      || ':' || COALESCE(prorate_minimum_days::text, '-'), ' ' ORDER BY code) INTO v_msg
      FROM leave_types WHERE default_days_per_year IS NOT NULL AND NOT is_accrued;
    IF v_msg <> 'childcare:3:prorate_first_year:-:2 compassionate:0:full:-:- examination:0:full:-:- extended_childcare:3:prorate_first_year:-:- '
                || 'hospitalisation:3:steps:{"3": 15, "4": 30, "5": 45}:- infant_care:3:full:-:- marriage:0:full:-:- maternity:3:full:-:- '
                || 'paternity:3:full:-:- shared_parental:3:full:-:- sick:3:steps:{"3": 5, "4": 8, "5": 11}:-' THEN
        RAISE EXCEPTION 'FIXTURE 290A 失败:leave_types 的服务期规矩不是 Tim 的裁定:%', v_msg; END IF;
    -- 本支下面的数假设引导的整年天数(14 · 60 · 6 · 2 · 112 · 3)
    IF (SELECT string_agg(code || '=' || trim_scale(default_days_per_year), ',' ORDER BY code) FROM leave_types
         WHERE code IN ('sick', 'hospitalisation', 'childcare', 'extended_childcare', 'maternity', 'marriage'))
       <> 'childcare=6,extended_childcare=2,hospitalisation=60,marriage=3,maternity=112,sick=14' THEN
        RAISE EXCEPTION 'FIXTURE 290A 布景失败:整年天数不是本支假设的引导值'; END IF;

    -- ══════════ B · 算式,逐个月份(入职 d0,请假日 = d0 + n 个月)═════════════════
    FOR c IN SELECT * FROM (VALUES
        -- 假别 · 完整月数 · 期望 · 怎么来的
        ('sick', 2, 0::numeric),             -- 不满 3 个月
        ('sick', 3, 5), ('sick', 4, 8), ('sick', 5, 11),   -- MOM 的台阶
        ('sick', 6, 14), ('sick', 30, 14),   -- 第 6 个月起整年
        ('hospitalisation', 2, 0), ('hospitalisation', 3, 15), ('hospitalisation', 4, 30), ('hospitalisation', 5, 45),
        ('hospitalisation', 6, 60),
        ('childcare', 2, 0),                 -- 不满 3 个月
        ('childcare', 3, 2),                 -- 6 × 3 ÷ 12 = 1.5 → 2(半天进位),也正好是下限 2
        ('childcare', 4, 2),                 -- 6 × 4 ÷ 12 = 2
        ('childcare', 5, 3),                 -- 2.5 → 3
        ('childcare', 7, 4),                 -- 3.5 → 4
        ('childcare', 11, 6),                -- 5.5 → 6
        ('childcare', 12, 6),                -- 满 12 个月整年
        ('extended_childcare', 3, 1),        -- 2 × 3 ÷ 12 = 0.5 → 1(没有下限)
        ('extended_childcare', 8, 1),        -- 1.33 → 1
        ('extended_childcare', 9, 2),        -- 1.5 → 2
        ('maternity', 2, 0), ('maternity', 3, 112),        -- 满 3 个月整年,不折算
        ('marriage', 0, 3)                   -- 公司政策:没有资格期
        ) x(t, m, want) LOOP
        v_got := pg_temp.f290_days(c.t, d0, (d0 + make_interval(months => c.m))::date);
        IF v_got IS DISTINCT FROM c.want THEN
            RAISE EXCEPTION 'FIXTURE 290B 失败:% 服务 % 个完整月应当 % 天,实得 %', c.t, c.m, c.want, v_got; END IF;
    END LOOP;

    -- B2 折算下限那一列真的在起作用。★ 用引导的 6 天它【咬不到】:满 3 个月 = 1.5 → 2,本来就是 2(注入矩阵第一版实测:
    --    拿掉下限,本支照样全绿)。所以这里把育儿假临时改成 2 天/年:3 个月 = 0.5 → 1,下限把它抬到 2;拿掉下限就是 1。
    UPDATE leave_types SET default_days_per_year = 2 WHERE code = 'childcare';
    v_got := pg_temp.f290_days('childcare', d0, (d0 + interval '3 months')::date);
    UPDATE leave_types SET default_days_per_year = 6 WHERE code = 'childcare';
    IF v_got IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'FIXTURE 290B2 失败:育儿假 2 天/年、服务 3 个月,折出 1 天,下限应当抬到 2,实得 %', v_got; END IF;

    -- ══════════ C · 完整的月 ════════════════════════════════════════════════
    IF (leave_service_entitlement('sick', DATE '2025-01-31', DATE '2025-02-28') ->> 'service_months')::int <> 0
       OR (leave_service_entitlement('sick', DATE '2025-01-31', DATE '2025-03-31') ->> 'service_months')::int <> 2
       OR (leave_service_entitlement('sick', DATE '2025-01-31', DATE '2025-04-30') ->> 'service_months')::int <> 2
       OR (leave_service_entitlement('sick', DATE '2025-01-31', DATE '2025-05-01') ->> 'service_months')::int <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 290C 失败:不满一个月的那一截不该算(1/31 → 2/28 = 0;→ 3/31 = 2;→ 4/30 = 2;→ 5/1 = 3)'; END IF;

    -- ══════════ D · 余额与提交 ════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    UPDATE leave_types SET is_active = true, requires_certificate_after_days = NULL WHERE code = 'sick';
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_new, now()), (u_mid, now()), (u_out, now());
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, employment_status, user_id) VALUES
        (e_new, 'FX290-NEW', 'FX290 New', 'full_time', 'office', CURRENT_DATE - 70,  'active', u_new),
        (e_mid, 'FX290-MID', 'FX290 Mid', 'full_time', 'office', (CURRENT_DATE - interval '4 months' - interval '3 days')::date, 'active', u_mid),
        (e_out, 'FX290-OUT', 'FX290 Out', 'full_time', 'office', DATE '2020-01-01', 'active', u_out);

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_new), true);
    v_bal := leave_balance(e_new, 'sick', CURRENT_DATE);
    IF (v_bal ->> 'available')::numeric <> 0 OR (v_bal ->> 'balance_checked')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 290D1 失败:入职 70 天的人病假应当 available = 0(查额度),实得 %', v_bal; END IF;
    v_msg := NULL;
    BEGIN
        PERFORM submit_leave_request(e_new, 'sick', CURRENT_DATE, CURRENT_DATE + 7, false, false, NULL, NULL, false, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS NULL OR v_msg NOT LIKE 'INSUFFICIENT_BALANCE|%' THEN
        RAISE EXCEPTION 'FIXTURE 290D2 失败:不满 3 个月的人提病假应当按名拒 INSUFFICIENT_BALANCE,实得 %', COALESCE(v_msg, '(提上去了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_mid), true);
    v_bal := leave_balance(e_mid, 'sick', CURRENT_DATE);
    IF (v_bal ->> 'available')::numeric <> 8
       OR (SELECT (b ->> 'service_months')::int FROM jsonb_array_elements(v_bal -> 'breakdown') b WHERE b ->> 'source' = 'yearly') <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 290D3 失败:入职 4 个多月的人病假应当 8 天、明细里写着 4 个月,实得 %', v_bal; END IF;

    -- ══════════ E · /me:一次调用,12 种 ═════════════════════════════════════
    v_all := leave_balances(e_mid);
    SELECT string_agg(x ->> 'leave_type_code', ',' ORDER BY ord) INTO v_codes
      FROM jsonb_array_elements(v_all) WITH ORDINALITY t(x, ord);
    IF jsonb_array_length(v_all) <> (SELECT count(*) FROM leave_types WHERE is_active AND (is_accrued OR default_days_per_year IS NOT NULL))
       OR v_codes <> (SELECT string_agg(code, ',' ORDER BY sort_order, code) FROM leave_types
                       WHERE is_active AND (is_accrued OR default_days_per_year IS NOT NULL))
       OR v_codes NOT LIKE 'annual,%' OR v_codes LIKE '%unpaid%' THEN
        RAISE EXCEPTION 'FIXTURE 290E1 失败:leave_balances 应当按 sort_order 回每一种有额度的假(年假在内、无薪假不在),实得 %', v_codes; END IF;
    IF (SELECT x ->> 'gender_restriction' FROM jsonb_array_elements(v_all) x WHERE x ->> 'leave_type_code' = 'maternity') <> 'female'
       OR (SELECT (x ->> 'available')::numeric FROM jsonb_array_elements(v_all) x WHERE x ->> 'leave_type_code' = 'sick') <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 290E2 失败:每一项应当带 gender_restriction,数与单独问 leave_balance 相同'; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_out), true);
    v_msg := NULL;
    BEGIN PERFORM leave_balances(e_mid);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.hr.view' THEN
        RAISE EXCEPTION 'FIXTURE 290E3 失败:别人(没有 hr.view)读一个员工的余额应当按名拒,实得 %', COALESCE(v_msg, '(读到了)'); END IF;

    RAISE NOTICE 'FIXTURE 290 全部通过:A 引导值 = 裁定 · B 逐月的算式 · C 完整的月 · D 余额与提交 · E /me 一次调用 12 种';
END $$;
ROLLBACK;
