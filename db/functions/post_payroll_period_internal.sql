-- db/functions/post_payroll_period_internal.sql
-- PAYROLL-APR-1(2026-09-24):工资过账的【引擎】—— 原 post_payroll_period 的函数体,
-- 只拿掉了 require_permission('module.hr.edit')。
--
-- 【为什么拆出来】批准之前要按【执行那一刻会用的同一支引擎】试跑一遍(payroll_request_dry_run),
-- 而批准的人是 CFO,CFO 不持 module.hr.edit。与 record_payment_internal 同一个理由、同一个形状:
-- 引擎没有调用者检查,靠的是调不到 —— EXECUTE 已从 authenticated 收回
-- (db/views/zzz_function_grants.sql)。唯一的外门是 post_payroll_period(要一张已批的申请)。
--
-- 函数体一个判据都没改:考勤依据(ATTEND-1)、币种、分录的五条腿、期间锁,原样。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql;
--       the body is post_payroll_period's as of db/migrations/2026-08-04-fin4-pay-per-employee.sql + ATTEND-1.

CREATE OR REPLACE FUNCTION public.post_payroll_period_internal(p_payroll_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_p     record;
    v_bank  text;
    v_lines jsonb := '[]'::jsonb;
    v_je    jsonb;
    v_cpf   numeric;
BEGIN
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_payroll_period_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status = 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p_payroll_period_id) THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- ══ ATTEND-1:★【过账要有依据,而依据是一句【人的断言】】★ ═════════════
    -- 【为什么拒在这里,而不是 upsert】记录服务商送回来的数字只是【捕获一个
    -- 已经发生的事实】,拦住它只会把那些数字推到系统外面去保管。
    -- 过账才是公司认下这些数字的那一刻,依据必须在这一刻存在。
    -- 【它并不检查"考勤对不对"】系统无从知道;它检查的是【有没有人说过
    -- 这个月的底稿齐全了】—— 与 finance_settings.system_start_date 是
    -- 【声明】而不是【推断】同一条。
    -- 【为什么必须是拒绝,而不是警告】一次静静地把"缺勤未知"当成"全勤"的
    -- 工资过账,是这里所有选项里最坏的一个;而一句没有牙齿的警告,
    -- 在一个月一次的收尾动作上会被直接点过去 —— 这个仓库为"学会忽略警报"
    -- 付过账。
    IF NOT EXISTS (
        SELECT 1 FROM attendance_periods ap
         WHERE ap.status = 'complete'
           AND ap.period_month = date_trunc('month', v_p.period_month)::date
    ) THEN
        RAISE EXCEPTION 'PAYROLL_ATTENDANCE_NOT_COMPLETE|%|%',
            v_p.code, to_char(v_p.period_month, 'YYYY-MM');
    END IF;

    -- FIN-4:过账【不碰银行】—— 钱还没出去。净额挂 2300 应付净薪,
    -- 逐人付款(pay_payroll_lines)时才贷银行,一人一条,各自对账。
    -- OPS-8:"支持哪些币种"就是 currencies 表本身,不是这里另抄一份码表
    IF NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = v_p.currency) THEN
        RAISE EXCEPTION 'PAYROLL_CURRENCY_UNSUPPORTED|%', v_p.currency;
    END IF;

    -- 借 6100 工资薪金(服务商口径的 gross)
    IF v_p.gross_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6100', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.gross_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 借 6110 公积金-雇主部分(公司成本,不从员工工资里出)
    IF v_p.employer_cpf_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6110', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.employer_cpf_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2400 公积金应付:雇主 + 员工两侧合计,汇给公积金局之前都欠着
    v_cpf := round(COALESCE(v_p.employer_cpf_total, 0) + COALESCE(v_p.employee_cpf_total, 0), 2);
    IF v_cpf > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2400', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_cpf, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2200 应计费用:服务商【代公司扣下】的其它款项,在汇出去之前挂在这里。
    -- 【注意区分】如果某项扣款本质上是"公司成本变少"(而不是替员工代扣代缴),
    -- 那它就不该出现在这里 —— 应该让服务商把它并进 gross 里去。
    IF v_p.other_deductions_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2200', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.other_deductions_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2300 应付净薪:实发净额,付给每个人之前都欠着
    IF v_p.net_pay_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2300', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.net_pay_total, 'fx_rate', v_p.fx_rate);
    END IF;

    -- 期间锁在 post_journal_entry 内生效(PERIOD_LOCKED 原样上抛)
    v_je := post_journal_entry(
        v_p.payment_date,
        'Payroll ' || v_p.code,
        'payroll',
        v_p.id,
        v_lines
    );

    UPDATE payroll_periods
    SET status = 'posted', journal_entry_id = (v_je->>'entry_id')::uuid, updated_by = v_user
    WHERE id = p_payroll_period_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_payroll_period_id,
        'code', v_p.code,
        'journal_code', v_je->>'code',
        'gross_total', v_p.gross_total,
        'employer_cpf_total', v_p.employer_cpf_total,
        'employee_cpf_total', v_p.employee_cpf_total,
        'net_pay_total', v_p.net_pay_total
    );
END;
$function$

;
