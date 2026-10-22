-- db/functions/reverse_payroll_payment_internal.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q2 · Q4 · Q5 · Q6 · Q7):冲掉一次工资【付款】—— 引擎(不问码)。
--
--   · 冲的是【一整张】付款分录(pay_payroll_lines 一次调用 = 一张分录;CPF / 扣款各一张)—— 不能只冲一个人(Q2)。
--     付对了的人,冲销之后再付一次。
--   · 哪一种付款,从【已付的戳】认(payroll_payment_entry_kind,Q7):工资 / CPF / 扣款同一种申请。认不出 → 按名拒
--     PAYROLL_PAYMENT_ENTRY_UNKNOWN(过账分录、已冲过而戳已清的付款、别的分录都落在这里)。
--   · 冲销日由人给、必填、不默认(Q3):REVERSAL_DATE_REQUIRED;晚于今天按名拒 DOCUMENT_DATE_IN_FUTURE|payroll_payment_reversal|…
--     (与六扇出钱的门同一句,Q4);早于原付款由 reverse_journal_entry_internal 按名拒 REVERSAL_BEFORE_ORIGINAL;
--     落在锁定期由 post_journal_entry 按期间锁拒 —— 原付款所在的月关了,冲销就选一个开着的月份,原件留在原地(Q4)。
--   · 付款的银行行已经配上了对账单行 → 按名拒 REVERSAL_BANK_MATCHED(assert_entry_not_bank_matched,Q6)。不自动取消配对。
--   · 冲完:期间【仍是 posted】;那张分录付过的行(含净额为零、没有银行行却同样盖了戳的行)清掉 paid_at 与
--     paid_journal_entry_id;CPF / 扣款清掉那一期的日期与分录链接(Q5)。于是那一期可以再付;一笔付款都不剩时,
--     既有的撤销过账申请又走得通(unpost_payroll_period_internal 的 PAYROLL_*_PAID 三道闸自然放行)。
--     历史留在申请行(target_entry_id · result_journal_entry_id)与那张已冲销的分录上。
--
-- 【调用者】reverse_payroll_payment(执行门,批过的申请)与 payroll_request_dry_run(提、批两次试跑,永远回滚)。
-- authenticated 收回了 EXECUTE(db/views/zzz_function_grants.sql)。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.reverse_payroll_payment_internal(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_je    journal_entries%ROWTYPE;
    v_kind  text;
    v_res   jsonb;
    v_n     integer := 0;
    v_pid   uuid;
BEGIN
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;
    IF p_reversal_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|payroll_payment_reversal|%|%', p_reversal_date, CURRENT_DATE;
    END IF;

    SELECT * INTO v_je FROM journal_entries WHERE id = p_entry_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JE_NOT_FOUND|%', COALESCE(p_entry_id::text, '?');
    END IF;
    v_kind := payroll_payment_entry_kind(v_je.id);
    IF v_je.source_type IS DISTINCT FROM 'payroll' OR v_kind IS NULL THEN
        RAISE EXCEPTION 'PAYROLL_PAYMENT_ENTRY_UNKNOWN|%', v_je.code;
    END IF;
    IF v_je.status <> 'posted' OR v_je.reversed_by IS NOT NULL THEN
        RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_je.code;
    END IF;

    PERFORM assert_entry_not_bank_matched(v_je.id);

    v_res := reverse_journal_entry_internal(v_je.id, p_reversal_date,
                 'Payroll payment reversal ' || v_je.code || COALESCE(' — ' || NULLIF(btrim(p_memo), ''), ''));

    IF v_kind = 'salary' THEN
        UPDATE payroll_lines
           SET paid_at = NULL, paid_journal_entry_id = NULL
         WHERE paid_journal_entry_id = v_je.id;
        GET DIAGNOSTICS v_n = ROW_COUNT;
    ELSIF v_kind = 'cpf' THEN
        UPDATE payroll_periods
           SET cpf_paid_at = NULL, cpf_journal_entry_id = NULL
         WHERE cpf_journal_entry_id = v_je.id;
        GET DIAGNOSTICS v_n = ROW_COUNT;
    ELSE
        UPDATE payroll_periods
           SET deductions_paid_at = NULL, deductions_journal_entry_id = NULL
         WHERE deductions_journal_entry_id = v_je.id;
        GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;
    v_pid := v_je.source_id;

    RETURN jsonb_build_object('entry_id', v_je.id, 'code', v_je.code, 'kind', v_kind,
                              'payroll_period_id', v_pid, 'cleared', v_n,
                              'reversal_id', v_res->>'reversal_id', 'reversal_code', v_res->>'code');
END;
$function$;
