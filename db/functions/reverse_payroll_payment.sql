-- db/functions/reverse_payroll_payment.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q1 · Q3):执行一张【批过的】工资付款冲销申请 —— 门。
--   财务执行(module.hr.edit;提单人也可以)。冲销日由执行的人给、必填、不默认(Q3)—— 那是钱真的回来的那一天;
--   日期的三道闸(不晚于今天 · 不早于原付款 · 不落在锁定期)在引擎与过账里(Q4)。
--   申请必须是这一种、而且是 approved:否则按名拒 PAYROLL_NEEDS_APPROVED_REQUEST|<申请>|payment_reversal。
--   批的那一组数(期间指纹)变了 → PAYROLL_CHANGED_SINCE_REQUEST(与另外两种同一句)。
--   银行行在批准之后才配上的 → 引擎按名拒 REVERSAL_BANK_MATCHED(Q6:执行时再判一次)。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.reverse_payroll_payment(p_request_id uuid, p_reversal_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r   payroll_requests%ROWTYPE;
    v_res jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;
    SELECT * INTO v_r FROM payroll_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.kind <> 'payment_reversal' OR v_r.status <> 'approved' THEN
        RAISE EXCEPTION 'PAYROLL_NEEDS_APPROVED_REQUEST|%|payment_reversal', v_r.label;
    END IF;
    IF payroll_period_fingerprint(v_r.payroll_period_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'PAYROLL_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    v_res := reverse_payroll_payment_internal(v_r.target_entry_id, p_reversal_date, v_r.notes);

    UPDATE payroll_requests
       SET status = 'executed', executed_at = now(), executed_by = auth.uid(),
           result_journal_entry_id = (v_res->>'reversal_id')::uuid
     WHERE id = v_r.id;

    RETURN v_res || jsonb_build_object('request_id', v_r.id, 'request_label', v_r.label);
END;
$function$;
