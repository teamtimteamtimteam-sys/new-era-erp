-- db/functions/pay_payroll_deductions.sql
-- 汇付某期间代扣的其它款项(FIN-5 B6)。payroll 过账把 other_deductions 挂 2200,
-- 此前【没有任何东西借得动它】—— 与 2400 同一个缺陷的第二处。
-- 代扣款是替员工代收、汇给第三方(保险/扣押令等)的【一笔】款,对账单 1 行,
-- 分录 1 条银行行 —— 照着对账单记,同 pay_payroll_cpf 的规则。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin5-relieve-cpf.sql.

CREATE OR REPLACE FUNCTION public.pay_payroll_deductions(p_payroll_period_id uuid, p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p    payroll_periods%ROWTYPE;
    v_amt  numeric;
    v_bank text;
    v_date date;
    v_je   jsonb;
BEGIN
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
    IF v_p.deductions_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_DEDUCTIONS_ALREADY_PAID|%', v_p.code;
    END IF;
    v_amt := round(COALESCE(v_p.other_deductions_total, 0), 2);
    IF v_amt <= 0 THEN
        RAISE EXCEPTION 'PAYROLL_NOTHING_TO_PAY|%', v_p.code;
    END IF;
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    v_date := COALESCE(p_payment_date, CURRENT_DATE);

    v_je := post_journal_entry(v_date, 'Payroll deductions ' || v_p.code, 'payroll', v_p.id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2200', 'side', 'debit',
                'currency', 'SGD', 'amount_ccy', v_amt, 'fx_rate', 1,
                'line_memo', 'Deductions for ' || v_p.code),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', 'SGD', 'amount_ccy', v_amt, 'fx_rate', 1)));

    UPDATE payroll_periods
    SET deductions_paid_at = v_date, deductions_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = v_p.id;

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'deductions_paid', v_amt,
                              'period', v_p.code, 'paid_on', v_date);
END;
$function$;
