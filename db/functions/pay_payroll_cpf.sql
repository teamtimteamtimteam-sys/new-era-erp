-- db/functions/pay_payroll_cpf.sql
-- 汇 CPF(FIN-5)。【与 FIN-4 刻意相反的形状,规则却是同一条:照着对账单记】——
-- 净薪是 ~15 个人各收一笔,对账单 15 行,所以分录 15 条银行行(pay_payroll_lines);
-- CPF 是给公积金局【一笔】汇款,对账单 1 行,所以分录【1 条】银行行。
-- 按人头的 CPF 明细在 payroll_lines 上,报局用查询,不用分录行(B3)。
-- 【单据记清结算的是哪个期间、何时付的】—— 当月的 CPF 次月才汇,两个月份不同是设计。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin5-relieve-cpf.sql.
--
-- FIN-10(2026-08-05):日期不再有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。
-- 默认成今天永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关,
-- 这条路径专门奖励留空。要求由函数自己声明,而不是靠调用方自觉。
-- 详见 db/migrations/2026-08-05-fin10-no-default-posting-dates.sql。

CREATE OR REPLACE FUNCTION public.pay_payroll_cpf(p_payroll_period_id uuid, p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p    payroll_periods%ROWTYPE;
    v_cpf  numeric;
    v_bank text;
    v_date date;
    v_je   jsonb;
BEGIN
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF NOT (has_permission('module.finance.edit') OR has_permission('module.hr.edit')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.edit';
    END IF;
    SELECT * INTO v_p FROM payroll_periods WHERE id = p_payroll_period_id FOR UPDATE;
    IF NOT FOUND OR v_p.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    IF v_p.cpf_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_CPF_ALREADY_PAID|%', v_p.code;
    END IF;
    v_cpf := round(COALESCE(v_p.employer_cpf_total, 0) + COALESCE(v_p.employee_cpf_total, 0), 2);
    IF v_cpf <= 0 THEN
        RAISE EXCEPTION 'PAYROLL_NOTHING_TO_PAY|%', v_p.code;
    END IF;
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    v_date := p_payment_date;

    v_je := post_journal_entry(v_date, 'CPF ' || v_p.code, 'payroll', v_p.id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2400', 'side', 'debit',
                'currency', 'SGD', 'amount_ccy', v_cpf, 'fx_rate', 1,
                'line_memo', 'CPF for ' || v_p.code),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', 'SGD', 'amount_ccy', v_cpf, 'fx_rate', 1,
                'line_memo', 'CPF Board')));

    UPDATE payroll_periods
    SET cpf_paid_at = v_date, cpf_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = v_p.id;

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'cpf_paid', v_cpf,
                              'period', v_p.code, 'paid_on', v_date);
END;
$function$;
