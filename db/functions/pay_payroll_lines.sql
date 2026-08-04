-- db/functions/pay_payroll_lines.sql
-- 发薪(FIN-4):付掉一个周期里【任意子集】的工资行 —— 转账会失败重发,
-- 所以一次付款跑批覆盖哪些行由调用方点名。一跑一张凭证:
--   借 2300 应付净薪(合计一条)
--   贷 银行 —— 【一人一条,金额 = 该人净额,备注 = 工号 + 姓名】
-- 每条银行行各自认领自己的对账单行,这是本切存在的理由(C3)。
-- 一行只许付一次(paid_at 即闸);发薪是银行操作,财务或 HR 都做得动。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin4-pay-per-employee.sql.
--
-- FIN-10(2026-08-05):日期不再有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。
-- 默认成今天永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关,
-- 这条路径专门奖励留空。要求由函数自己声明,而不是靠调用方自觉。
-- 详见 db/migrations/2026-08-05-fin10-no-default-posting-dates.sql。

CREATE OR REPLACE FUNCTION public.pay_payroll_lines(p_payroll_period_id uuid, p_line_ids uuid[], p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p     payroll_periods%ROWTYPE;
    v_bank  text;
    v_date  date;
    v_total numeric := 0;
    v_lines jsonb := '[]'::jsonb;
    v_l     record;
    v_n     integer := 0;
    v_je    jsonb;
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
    IF p_line_ids IS NULL OR array_length(p_line_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_bank := COALESCE(p_bank_account, CASE v_p.currency WHEN 'SGD' THEN '1000' ELSE '1010' END);
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    v_date := p_payment_date;

    FOR v_l IN
        SELECT pl.id, pl.net_pay, pl.paid_at, e.code AS emp_code, e.legal_name
        FROM payroll_lines pl
        JOIN employees e ON e.id = pl.employee_id
        WHERE pl.id = ANY (p_line_ids)
        ORDER BY e.code
        FOR UPDATE OF pl
    LOOP
        IF NOT EXISTS (SELECT 1 FROM payroll_lines x
                       WHERE x.id = v_l.id AND x.payroll_period_id = p_payroll_period_id) THEN
            RAISE EXCEPTION 'PAYROLL_LINE_INVALID|%', v_l.id;
        END IF;
        IF v_l.paid_at IS NOT NULL THEN
            RAISE EXCEPTION 'PAYROLL_LINE_ALREADY_PAID|%', v_l.emp_code;
        END IF;
        IF v_l.net_pay <= 0 THEN
            CONTINUE;  -- 净额为零的行没有转账,也没有对账单行
        END IF;
        -- 【一人一条银行行】备注带工号姓名,statement 上那一行就是这一条
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_bank, 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_l.net_pay, 'fx_rate', 1,
            'line_memo', v_l.emp_code || ' ' || v_l.legal_name);
        v_total := round(v_total + v_l.net_pay, 2);
        v_n := v_n + 1;
    END LOOP;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_lines := jsonb_build_array(jsonb_build_object(
        'account_code', '2300', 'side', 'debit', 'currency', v_p.currency,
        'amount_ccy', v_total, 'fx_rate', 1,
        'line_memo', 'Salary run ' || v_p.code)) || v_lines;

    v_je := post_journal_entry(v_date, 'Salary payment ' || v_p.code, 'payroll',
                               p_payroll_period_id, v_lines);

    UPDATE payroll_lines
    SET paid_at = now(), paid_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = ANY (p_line_ids);

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'entry_id', v_je->>'entry_id',
                              'lines_paid', v_n, 'total_paid', v_total);
END;
$function$;
