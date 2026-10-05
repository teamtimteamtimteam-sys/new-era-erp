-- db/functions/medical_claim_balance.sql
-- 医疗报销额度:按当年完整服务月数折算,取整到元。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
--
-- HR-6(2026-08-05):以 finance_settings.system_start_date 为界。
-- 额度是【推导】的、已用额是【记录】的 —— 切换前的报销不在本库,于是整份额度
-- 会重新可用,而 decide_medical_claim 就拿这个 remaining 当闸门(真的多批钱)。
-- 整年早于起始日 → 拒;起始日落在年内 → 额度按覆盖月份折算;未设 → 拒。

CREATE OR REPLACE FUNCTION public.medical_claim_balance(p_employee_id uuid, p_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_set    record;
    v_months integer := 12;
    v_limit  numeric;
    v_used   numeric;
    v_start  date;      -- 本库自哪天起持有完整记录
    v_from_m integer;   -- 本年度从第几个月起算(入职月 / 完整记录起始月,取较晚者)
BEGIN
    -- ★ U1-A(Tim 的 UNBLOCK-1 Q8,2026-10-05):门从 module.hr.view 收成 data.view_health —— 已用额就是这个人这一年
    --   医疗报销金额的合计,而那个金额(medical_claims.amount_sgd)从本刀起只给持 data.view_health 的人与本人。
    --   本人照旧(/me 的额度面板);决定医疗报销的人(action.decide_hr_requests:admin · cco · cfo · finance)都持这一码,
    --   所以 decide_medical_claim 里那一次调用照旧过得去。
    --   ★ COALESCE 是承重的(U1-A 量到的、本刀之前就在的缺陷):一个【没有员工档案】的账号,current_user_employee() 是 NULL,
    --     于是 "p_employee_id = NULL" 是 NULL,NOT (false OR NULL) 也是 NULL —— IF NULL 不进分支,这道门对它【从来没有关过】。
    IF NOT (has_permission('data.view_health') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|data.view_health';
    END IF;

    SELECT id, code, hire_date INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    SELECT * INTO v_set FROM hr_settings WHERE id;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【额度是推导的,消耗是记录的 —— 全新库有前者没有后者】
    -- 年度额度由政策推导(每年 1000),已用额则来自 medical_claims 里【记录】的行。
    -- 切换上线时,切换前已报销的部分不在本库里,于是 used 偏低、remaining 偏高,
    -- 整份年度额度重新可用。而 decide_medical_claim 就是拿这个 remaining 当闸门的
    -- (CLAIM_EXCEEDS_LIMIT),所以这不是显示问题,是【真的会多批钱出去】。
    --
    -- 处置与 HR-5 的结转同一形状:
    --   * 整年都早于完整记录起始日 → 拒绝(那一年本库一无所知,给出任何余额都是编的);
    --   * 起始日落在本年度之内 → 把额度【按本库覆盖的月份】折算。
    --     理由:切换前的额度【与消耗】都在本库之外,两者一起排除是自洽的;
    --     而"整份额度 + 零消耗"不自洽。折算方向偏保守(可能少给,不会多批),
    --     少给的那部分由下面那条路补回来。
    --
    -- 【想恢复整份年度额度怎么办】把切换前的报销作为 medical_claims 行补录进来,
    -- 并把 system_start_date 前移到最早那笔真实交易 —— 那一年就【完整】了,
    -- 折算自动消失。见 docs/fresh-install-checklist.md。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT system_start_date INTO v_start FROM finance_settings LIMIT 1;
    IF v_start IS NULL THEN
        RAISE EXCEPTION 'SYSTEM_START_NOT_SET';
    END IF;
    IF make_date(p_year, 12, 31) < v_start THEN
        RAISE EXCEPTION 'CLAIM_YEAR_BEFORE_SYSTEM_START|%|%', p_year, v_start;
    END IF;

    v_from_m := 1;
    IF v_set.medical_pro_rate_for_joiners AND EXTRACT(YEAR FROM v_emp.hire_date)::integer = p_year THEN
        v_from_m := EXTRACT(MONTH FROM v_emp.hire_date)::integer;
    END IF;
    -- 完整记录的起始月【不是政策选项,是关于数据的事实】,所以不看
    -- medical_pro_rate_for_joiners 那个开关,一律生效。
    IF EXTRACT(YEAR FROM v_start)::integer = p_year THEN
        v_from_m := GREATEST(v_from_m, EXTRACT(MONTH FROM v_start)::integer);
    END IF;
    v_months := 12 - (v_from_m - 1);
    v_limit := round(v_set.medical_annual_limit_sgd * v_months / 12.0, 0);

    SELECT COALESCE(SUM(amount_sgd), 0) INTO v_used
    FROM medical_claims
    WHERE employee_id = p_employee_id AND claim_year = p_year
      AND deleted_at IS NULL AND status IN ('approved','paid');

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code, 'year', p_year,
        'annual_limit_sgd', v_set.medical_annual_limit_sgd,
        'months_of_service', v_months,
        'pro_rated_limit_sgd', v_limit,
        'record_complete_from', v_start,
        'record_incomplete_for_year', EXTRACT(YEAR FROM v_start)::integer = p_year
                                     AND EXTRACT(MONTH FROM v_start)::integer > 1,
        'claimed_sgd', v_used,
        'remaining_sgd', v_limit - v_used);
END;
$function$;
