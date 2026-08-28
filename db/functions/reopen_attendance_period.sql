CREATE OR REPLACE FUNCTION public.reopen_attendance_period(p_period_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_p attendance_periods%ROWTYPE; v_pay text;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM attendance_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_FOUND|%', COALESCE(p_period_id::text, '?');
    END IF;
    IF v_p.status <> 'complete' THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_COMPLETE|%|%', v_p.code, v_p.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ATTENDANCE_REOPEN_REASON_REQUIRED|%', v_p.code;
    END IF;

    -- ★【那个月的工资已经过账,就不许再动它的依据】★
    -- 一张已过账工资单的依据不能在它脚下改变。改法是先 unpost ——
    -- 而 unpost_payroll_period 自己带着守卫(CPF/扣款已汇出就拒),
    -- 所以这条顺序是可执行的,不是一句劝告。
    SELECT code INTO v_pay FROM payroll_periods
     WHERE deleted_at IS NULL AND status = 'posted'
       AND date_trunc('month', period_month)::date = v_p.period_month LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL|%|%', v_p.code, v_pay;
    END IF;

    UPDATE attendance_periods
       SET status = 'open', completed_at = NULL, completed_by = NULL,
           reopened_at = now(), reopened_by = auth.uid(), reopen_reason = btrim(p_reason)
     WHERE id = p_period_id;

    RETURN jsonb_build_object('period_id', p_period_id, 'code', v_p.code, 'status', 'open');
END;
$function$

;
