CREATE OR REPLACE FUNCTION public.unpost_payroll_period(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_p    record;
    v_je   jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;
    -- FIN-4:已有工资行付了钱,冲销周期会让那些结算变孤儿 —— 拒绝,先冲付款
    IF EXISTS (SELECT 1 FROM payroll_lines
               WHERE payroll_period_id = p_id AND paid_at IS NOT NULL) THEN
        RAISE EXCEPTION 'PAYROLL_LINES_PAID|%', v_p.code;
    END IF;
    -- FIN-5:CPF / 代扣款已汇出的期间同理 —— 先冲那笔汇款
    IF v_p.cpf_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_CPF_PAID|%', v_p.code;
    END IF;
    IF v_p.deductions_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_DEDUCTIONS_PAID|%', v_p.code;
    END IF;

    -- 冲销分录;原分录留在账上并被标记为已冲销 —— 不删账
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个。薪资按【发薪日】过账,而发薪日
    -- 可以晚于今天(28 号过账、月末发薪);撤回一张还没到发薪日的薪资是正当的更正,
    -- 所以冲销落在发薪日,而不是被 REVERSAL_BEFORE_ORIGINAL 拒掉。
    v_je := reverse_journal_entry_internal(v_p.journal_entry_id, reversal_date_for(v_p.journal_entry_id), 'Payroll reversal ' || v_p.code);

    UPDATE payroll_periods
    SET status = 'draft',
        journal_entry_id = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unposted] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_id,
        'code', v_p.code,
        'status', 'draft',
        'reversal_journal_code', v_je->>'code'
    );
END;
$function$;