-- db/functions/submit_payroll_payment_reversal_request.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q1):提一张【工资付款冲销】申请 —— payroll_requests 的第三种(payment_reversal)。
--   财务提(module.hr.edit,工资期本来就归这个码;finance 角色持有它)· CFO 批每一张、不分档(decide_payroll_request,不改)·
--   财务执行(reverse_payroll_payment,提单人也可以)。审批关着时生下来就是 approved(auto_approved),与另外两种同形。
--   期间冻结与「一期同时只挂一张未了结的申请」照用(payroll_requests_one_open_per_period)。
--   理由必填:审批人读的就是它,也是冲销分录摘要里那一句。
--   提交时就以【今天】为探测日试跑一次真引擎(payroll_request_dry_run,永远回滚):已冲过、认不出、银行行已配对(Q6)
--   都在 CFO 看见之前按引擎原话拒;真正的冲销日在执行时由人给(Q3)。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.submit_payroll_payment_reversal_request(p_entry_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_je    journal_entries%ROWTYPE;
    v_p     payroll_periods%ROWTYPE;
    v_id    uuid := gen_random_uuid();
    v_on    boolean := approvals_enabled();
    v_label text;
    v_n     integer;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_je FROM journal_entries WHERE id = p_entry_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JE_NOT_FOUND|%', COALESCE(p_entry_id::text, '?');
    END IF;
    IF v_je.source_type IS DISTINCT FROM 'payroll' OR payroll_payment_entry_kind(v_je.id) IS NULL THEN
        RAISE EXCEPTION 'PAYROLL_PAYMENT_ENTRY_UNKNOWN|%', v_je.code;
    END IF;
    SELECT * INTO v_p FROM payroll_periods
     WHERE id = v_je.source_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(v_je.source_id::text, '?');
    END IF;
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'PAYROLL_REVERSAL_REASON_REQUIRED|%', v_p.code;
    END IF;
    IF EXISTS (SELECT 1 FROM payroll_requests r
                WHERE r.payroll_period_id = v_p.id AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_OPEN|%', v_p.code;
    END IF;

    PERFORM assert_other_decider('payroll_request', 'decide_payroll_request', 2::smallint,
                                 'PAYROLL_NO_OTHER_DECIDER|' || v_p.code);

    SELECT count(*) + 1 INTO v_n FROM payroll_requests
     WHERE payroll_period_id = v_p.id AND kind = 'payment_reversal';
    v_label := v_p.code || ' · payment_reversal #' || v_n::text;

    INSERT INTO payroll_requests (id, payroll_period_id, kind, status, label, snapshot,
                                  currency, fx_rate, gross_total, amount_base, notes, created_by, target_entry_id)
    VALUES (v_id, v_p.id, 'payment_reversal',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            v_label, payroll_period_fingerprint(v_p.id),
            v_p.currency, v_p.fx_rate, v_p.gross_total, round(v_p.gross_total * v_p.fx_rate, 2),
            btrim(p_notes), auth.uid(), v_je.id);

    PERFORM payroll_request_dry_run(v_id);

    IF v_on THEN
        PERFORM record_approval_decision('payroll_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payroll_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'label', v_label, 'entry_code', v_je.code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$;
