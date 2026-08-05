-- HR-6:医疗额度也按"完整记录起始日"设界;并把 system_start_date 的语义写准。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么这个比结转更急】它会直接多批钱出去
-- ════════════════════════════════════════════════════════════════════════════
-- 年度医疗额度由政策【推导】(hr_settings.medical_annual_limit_sgd),已用额来自
-- medical_claims 里【记录】的行。切换上线时,切换前已报销的部分不在本库 ——
-- used 偏低、remaining 偏高,整份年度额度重新可用。
-- 而 decide_medical_claim 正是拿这个 remaining 当闸门(CLAIM_EXCEEDS_LIMIT),
-- 所以这不是显示错,是【审批会放过本该超限的报销】。
--
-- 处置(与 HR-5 结转同形):
--   * 整年都早于起始日 → 拒绝(CLAIM_YEAR_BEFORE_SYSTEM_START);
--   * 起始日落在本年度内 → 额度按本库【覆盖的月份】折算。
--     切换前的额度与消耗都在本库之外,一起排除是自洽的;"整份额度 + 零消耗"不自洽。
--     方向偏保守:可能少给,不会多批。
--   * 未设起始日 → 拒绝(SYSTEM_START_NOT_SET),与结转一致。
-- 返回值新增 record_complete_from / record_incomplete_for_year,好让界面解释这个数
-- 是怎么来的,而不是让人对着一个变小了的额度猜。
--
-- 【想要整份年度额度,就把记录补全】把切换前的报销作为 medical_claims 行补录,
-- 并把 system_start_date 前移到最早那笔真实交易 —— 那一年就完整了,折算自动消失。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【顺带订正 system_start_date 的列注释】
-- HR-5 把它写成"开始运营的日期(安装时申报)"。那说的是【时机】,不是【含义】,
-- 而含义决定取值:它是【本库自哪一天起持有完整记录】。
-- 若计划把切换前的交易补录进来,这个日期就该是【最早那笔真实交易】,而不是切换日 ——
-- 两者可能相差几个月。取错了不会报错,只会让所有以它为界的守卫【站错位置】。

BEGIN;

COMMENT ON COLUMN public.finance_settings.system_start_date IS
    '本库自哪一天起持有【完整】记录 —— 不是安装日、也不一定是切换日。若切换前的交易会被补录进来,取【最早那笔真实交易】的日期。所有年度性守卫(年末结转、医疗额度)以它为界:早于它的期间,本库的数据不完整,任何据此推算的余额或额度都是凭空的。取错不会报错,只会让守卫站错位置。';

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
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
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

COMMIT;
