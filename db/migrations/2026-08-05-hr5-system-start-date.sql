-- HR-5:申报"本库从哪天开始运营",并据此拒绝跨越它的年末结转。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【问题】carry_forward_annual_leave 会无中生有
-- ════════════════════════════════════════════════════════════════════════════
-- 结转额 = accrued_annual_leave(员工, 目标年末) − 该年已用。累积按【入职日】往回算,
-- 完全不问"本库那一年在不在运行"。于是:2027 年才建起来的库上跑"结转 2026 → 2027",
-- 一位 2020 年入职的员工会算出 2026 全年累积、零消耗 —— 凭空多出一年的假期余额,
-- 数字合理、无报错、事后极难发现。
--
-- 今天这家公司没有历史(第一位员工 2026-08-01 入职),所以现在没有东西要迁。
-- 但切换上线可能发生在 2027 年,那时 2026 的余额是【真的】—— 它们在测试库里累积与
-- 消耗过,而测试库不会被迁移过去。届时跑一次结转,就正好落进上面那个陷阱。
--
-- 【为什么是"申报的开始日"而不是"最早的业务数据"】
-- 后者是推断:任何人补录一条更早的单据,界线就自己移动,而且没人会察觉。
-- 前者是声明:只有改配置才会变。**历史余额必须作为一个明确的动作到达,
-- 不能是推导出来的副产品。**
--
-- 【NULL 一律拒绝,不当成"不限制"】没设开始日 = 不知道本库何时开始 ——
-- 而"从一个不知道的基线往前结转"正是要防的那件事。结转一年一次,
-- 要求先把这个日期填上,是相称的。
--
-- 【历史余额的正确入口】手工写 leave_grants(grant_type、notes 记明来源与依据),
-- 见 docs/fresh-install-checklist.md。拒绝要指向别处,不能只是挡住。

BEGIN;

ALTER TABLE public.finance_settings ADD COLUMN system_start_date date;

COMMENT ON COLUMN public.finance_settings.system_start_date IS
    '本数据库开始运营的日期(安装时申报)。早于它的年度动作一律拒绝 —— 那些期间的数据不在本库里,任何据此推算的余额都是凭空造的。历史余额请手工写 leave_grants。';

CREATE OR REPLACE FUNCTION public.carry_forward_annual_leave(p_leave_year integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp     record;
    v_year_end date := make_date(p_leave_year, 12, 31);
    v_sys_start date;
    v_accrued numeric;
    v_used    numeric;
    v_balance numeric;
    v_rows    jsonb := '[]'::jsonb;
    v_count   integer := 0;
    v_total   numeric := 0;
BEGIN
    PERFORM require_permission('module.hr.edit');

    -- ════════════════════════════════════════════════════════════════════════
    -- 【结转不许跨过"本库开始运营"那一天】
    -- 结转额 = accrued_annual_leave(员工, 目标年末) − 该年已用。而累积是按【入职日】
    -- 往回算的,与"本库那一年有没有在运行"毫无关系。于是在一个 2027 年才建起来的库上
    -- 结转 2026,会给 2020 年入职的人算出满满一年累积、零消耗 —— 凭空造出一年的余额,
    -- 数字看着完全合理,没有任何报错。
    --
    -- 【为什么用"申报的开始日",而不是"最早的业务数据"】后者是【推断】出来的:
    -- 任何人补录一条更早的单据,那条界线就自己移动了,而且没人会注意到。
    -- 前者是【声明】出来的,只有改配置才会变。历史余额必须作为一个明确的动作到达,
    -- 不能是推导出来的副产品。
    --
    -- 历史余额的正确入口:手工写 leave_grants 行(grant_type='opening',notes 写明来源),
    -- 见 docs/fresh-install-checklist.md。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT system_start_date INTO v_sys_start FROM finance_settings LIMIT 1;
    IF v_sys_start IS NULL THEN
        RAISE EXCEPTION 'SYSTEM_START_NOT_SET';
    END IF;
    IF v_year_end < v_sys_start THEN
        RAISE EXCEPTION 'CARRY_FORWARD_BEFORE_SYSTEM_START|%|%', p_leave_year, v_sys_start;
    END IF;

    FOR v_emp IN
        SELECT e.id, e.code FROM employees e
        WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'
        ORDER BY e.code
    LOOP
        IF EXISTS (SELECT 1 FROM leave_grants g
                   WHERE g.employee_id = v_emp.id AND g.leave_type_code = 'annual'
                     AND g.grant_type = 'carry_forward' AND g.leave_year = p_leave_year + 1
                     AND g.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'CARRY_FORWARD_EXISTS|%|%', v_emp.code, p_leave_year;
        END IF;

        v_accrued := accrued_annual_leave(v_emp.id, v_year_end);
        v_used    := consumed_from_accrual(v_emp.id, p_leave_year);
        v_balance := v_accrued - v_used;

        IF v_balance IS NULL OR v_balance <= 0 THEN CONTINUE; END IF;

        INSERT INTO leave_grants (employee_id, leave_type_code, leave_year, days, granted_on,
                                  expires_on, grant_type, source_grant_id, notes)
        VALUES (v_emp.id, 'annual', p_leave_year + 1, v_balance,
                make_date(p_leave_year + 1, 1, 1),
                make_date(p_leave_year + 1, 12, 31),
                'carry_forward',
                -- 【没有来源授予行了】当年度是派生的,所以 source_grant_id 为空。
                -- leave_balance 的 carried_out 扣减因此对它无事可做,也就无从重复计数。
                NULL,
                format('Carried forward from %s monthly accrual (%s accrued, %s taken)',
                       p_leave_year, trim_scale(v_accrued), trim_scale(v_used)));

        v_count := v_count + 1;
        v_total := v_total + v_balance;
        v_rows := v_rows || jsonb_build_object('employee_code', v_emp.code, 'days', v_balance,
                                               'accrued', v_accrued, 'taken', v_used);
    END LOOP;

    RETURN jsonb_build_object('from_year', p_leave_year, 'into_year', p_leave_year + 1,
                              'employees', v_count, 'total_days', v_total,
                              'source', 'derived monthly accrual', 'detail', v_rows);
END;
$function$;

COMMIT;
