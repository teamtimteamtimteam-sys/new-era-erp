-- db/migrations/2026-08-03-ops3-definer-caller-checks.sql
-- OPS-3:七个 SECURITY DEFINER 函数【任何登录用户都能直接调】,读到别人的假期数据。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【实测,不是推演】一个零模块权限的员工,对着另一名员工的 id:
--     leave_balance(victim)            refused: PERMISSION_DENIED|module.hr.view
--     leave_balance_internal(victim)   *** LEAKED *** available=31 accrued=24
--     accrued_annual_leave(victim)     *** LEAKED *** 24
--     accrued_annual_leave_detail      *** LEAKED *** employee_code=LK-VICTIM
--     available_annual_accrual         *** LEAKED *** 24
--     consumed_from_accrual            *** LEAKED *** 0
--     annual_leave_rate_per_year       *** LEAKED *** 24
--     annual_leave_available_from      *** LEAKED *** 2026-01-31
-- 对外的包装函数拒绝了,而【隔着一次函数调用】的内层原样交了出来。
-- anon 也拿得到 —— 匿名 key 是随应用公开发出去的。
--
-- 【为什么会这样】HR-2c/HR-3c 把"算式"与"权限"分开是对的(属主权限视图要复用算式,
-- 不能被权限检查挡住),但分开之后【没有把内层收回来】。Supabase 的默认权限
-- 会把 public 架构里每个函数的 EXECUTE 授给 anon 与 authenticated,所以"内部函数"
-- 只是【命名上】内部,权限上是公开的。
--
-- 【这个仓库里本来就有正确的做法】财务那两个内层函数早就收回了:
--     calculate_metal_price_internal   auth_exec=False  anon=False
--     reverse_journal_entry_internal   auth_exec=False  anon=False
-- 本切把同一套做法补到假期这边。
--
-- 【两种修法,按是否有界面调用来选】
--   * 没有任何界面调用的六个 → REVOKE EXECUTE。它们只被属主权限视图和
--     带权限检查的包装函数调用,而属主权限视图以视图属主的身份执行,不受影响。
--   * annual_leave_available_from 有一处界面调用(提交请假被拒之后补一句"几号才够")
--     → 不能收回,改为【在函数里检查】,口径与 leave_balance 一致。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.annual_leave_available_from(p_employee_id uuid, p_days numeric, p_from date DEFAULT CURRENT_DATE)
 RETURNS date
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_from)::integer;
    v_m    date := date_trunc('month', p_from)::date;
    v_end  date;
BEGIN
    -- 【本人或 HR】—— 与 leave_balance 同一道口径。界面在 INSUFFICIENT_ACCRUED_LEAVE
    -- 之后调它,那时调用者要么是本人、要么持 module.hr.edit,两种都过得去。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    -- 逐个月末往前推:哪一个月末的可用余额够了,那天起就订得动。
    -- 累积在月末落账,所以「够了的那天」就是那个月末本身。
    WHILE v_m <= make_date(v_year, 12, 1) LOOP
        v_end := (v_m + interval '1 month' - interval '1 day')::date;
        IF v_end >= p_from
           AND (leave_balance_internal(p_employee_id, 'annual', v_end)->>'available')::numeric >= p_days THEN
            RETURN v_end;
        END IF;
        v_m := (v_m + interval '1 month')::date;
    END LOOP;
    -- 本假期年度内都攒不够 —— 返回 NULL,界面据此说另一句话,而不是编一个日期出来。
    RETURN NULL;
END;
$function$;

-- 【原本想用 REVOKE,实测证明那是错的】收回 EXECUTE 之后 employees_masked 当场坏掉:
--     ERROR: permission denied for function accrued_annual_leave
-- 属主权限视图(security_invoker = off)对【基表】按视图属主判权限,但视图体里
-- 调用的【函数】仍然按调用者判 EXECUTE。所以"内层函数只给视图用"这个前提不成立 ——
-- 调用者本来就必须拿得到 EXECUTE。既然如此,把检查放回函数里才是唯一说得通的修法,
-- "算式与权限分开"这个理由也就随之消失了(它当初就没成立过)。
--
-- 六个函数一律加同一道口径的检查:本人,或 module.hr.view。
-- 视图的行谓词【正是同一个布尔量】,所以视图取得出来的每一行,函数都放行 —— 实测过。
-- 其中四个原本是 LANGUAGE sql,为了能 RAISE 改成 plpgsql,函数体一字未动。

CREATE OR REPLACE FUNCTION public.leave_balance_internal(p_employee_id uuid, p_leave_type_code text DEFAULT 'annual'::text, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_break   jsonb := '[]'::jsonb;
    v_granted numeric := 0;
    v_used    numeric := 0;
    v_expired numeric := 0;
    v_avail   numeric := 0;
    v_accrued numeric := 0;
    v_acc_used numeric := 0;
    v_year    integer := EXTRACT(YEAR FROM p_as_of)::integer;
    r         record;
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    FOR r IN
        SELECT g.id, g.leave_year, g.days, g.granted_on, g.expires_on, g.grant_type,
               COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                         FROM leave_consumption c WHERE c.leave_grant_id = g.id), 0) AS consumed,
               -- 【已被结转走的部分】。结转是把剩余【搬到】下一年的一笔新授予里,
               -- 不是复制一份 —— 若不在这里扣掉,同样的天数会在来源授予和结转授予里
               -- 【各算一次】,余额凭空翻倍。这一条是本切最容易做错的地方之一。
               COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                         WHERE cf.source_grant_id = g.id AND cf.grant_type = 'carry_forward'
                           AND cf.deleted_at IS NULL), 0) AS carried_out
        FROM leave_grants g
        WHERE g.employee_id = p_employee_id AND g.leave_type_code = p_leave_type_code
          AND g.deleted_at IS NULL AND g.granted_on <= p_as_of
        ORDER BY g.expires_on NULLS LAST, g.granted_on
    LOOP
        v_granted := v_granted + r.days;
        v_used := v_used + r.consumed;
        IF r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0 THEN
            NULL;
        ELSIF r.expires_on IS NOT NULL AND r.expires_on < p_as_of THEN
            v_expired := v_expired + (r.days - r.consumed - r.carried_out);
        ELSE
            v_avail := v_avail + (r.days - r.consumed - r.carried_out);
        END IF;
        v_break := v_break || jsonb_build_object(
            'source', 'grant',
            'grant_id', r.id, 'leave_year', r.leave_year, 'grant_type', r.grant_type,
            'days', r.days, 'consumed', r.consumed, 'carried_forward_out', r.carried_out,
            'remaining', r.days - r.consumed - r.carried_out,
            'expires_on', r.expires_on,
            'status', CASE WHEN r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0
                                THEN 'carried_forward'
                           WHEN r.expires_on IS NOT NULL AND r.expires_on < p_as_of
                                THEN 'expired' ELSE 'active' END);
    END LOOP;

    -- ── 第二个来源:当年度的派生累积(只有年假) ─────────────────────────────
    -- 【它没有 expires_on】—— 于是"先用旧的"天然把它排在结转行之后,
    -- 也于是失效逻辑【碰不到它】:没有可比的日期,当年挣的天数无从作废(D4)。
    IF p_leave_type_code = 'annual' THEN
        v_accrued  := accrued_annual_leave(p_employee_id, p_as_of);
        v_acc_used := consumed_from_accrual(p_employee_id, v_year);
        v_granted := v_granted + v_accrued;
        v_used    := v_used + v_acc_used;
        v_avail   := v_avail + (v_accrued - v_acc_used);
        v_break := v_break || jsonb_build_object(
            'source', 'accrual',
            'grant_id', NULL, 'leave_year', v_year, 'grant_type', 'monthly_accrual',
            'days', v_accrued, 'consumed', v_acc_used, 'carried_forward_out', 0,
            'remaining', v_accrued - v_acc_used,
            'expires_on', NULL, 'status', 'active');
    END IF;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'leave_type_code', p_leave_type_code, 'as_of', p_as_of,
        'granted', v_granted, 'consumed', v_used, 'expired', v_expired,
        'accrued_this_year', v_accrued, 'consumed_from_accrual', v_acc_used,
        -- 【向下取到 0.5】—— 结转与消耗本就是 0.5 的整数倍,这里是防御性的一层
        'available', trim_scale(floor(v_avail * 2) / 2),
        'breakdown', v_break);
END;
$function$;

CREATE OR REPLACE FUNCTION public.accrued_annual_leave(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN (SELECT (accrued_annual_leave_detail(p_employee_id, p_as_of)->>'accrued_days')::numeric);
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.available_annual_accrual(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN (SELECT accrued_annual_leave(p_employee_id, p_as_of)
         - consumed_from_accrual(p_employee_id, EXTRACT(YEAR FROM p_as_of)::integer));
END;
$function$;

CREATE OR REPLACE FUNCTION public.consumed_from_accrual(p_employee_id uuid, p_leave_year integer)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN (SELECT COALESCE(SUM(CASE WHEN c.entry_type = 'draw' THEN c.days ELSE -c.days END), 0)
    FROM leave_consumption c
    JOIN leave_requests r ON r.id = c.leave_request_id
    WHERE c.accrual_year = p_leave_year AND r.employee_id = p_employee_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.annual_leave_rate_per_year(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    RETURN (SELECT (leave_accrual_rate(
                p_employee_id,
                employee_work_category_at(p_employee_id, date_trunc('month', p_as_of)::date),
                date_trunc('month', p_as_of)::date
            )->>'days_per_year')::numeric);
END;
$function$;

COMMIT;
