-- db/functions/submit_payroll_request.sql
-- PAYROLL-APR-1(2026-09-24):提一张工资申请 —— 过账(post)或撤销过账(reversal)。
--
-- Tim 的矩阵 §5:财务提(module.hr.edit —— 工资期本来就归这个码),CFO 批每一张、不分档。
--   · post     —— 期间必须是 draft、有行;
--   · reversal —— 期间必须是 posted;理由必填(PAYROLL_REVERSAL_REASON_REQUIRED),
--                 审批人读的就是它,执行时它也是撤销分录上的那一句。
--   · 一个期间同时只挂一张未了结的申请(PAYROLL_REQUEST_OPEN;唯一索引是第二道)。
--   · snapshot = payroll_period_fingerprint:批的那一组数(grilling Q4)。
--   · 提交时照执行那一刻的同一支引擎试跑一遍(payroll_request_dry_run,grilling Q7)——
--     考勤没做齐、期间已锁、已付过钱,这里就按引擎的原话拒,而不是等 CFO 批完才撞上。
--
-- 【审批关着时】生下来就是 approved,留痕 auto_approved —— 没有人按过批准,留痕就不许说有人按过
-- (采购单与付款申请同形,PAY-REQ-1 的 Q8)。
-- 【主角】工资期是公司的单据(Tim 的 Q1 (A)):留痕的主角为 NULL,见 payroll_requests 抬头。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_payroll_request(p_payroll_period_id uuid, p_kind text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p     payroll_periods%ROWTYPE;
    v_id    uuid := gen_random_uuid();
    v_on    boolean := approvals_enabled();
    v_label text;
    v_n     integer;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_p FROM payroll_periods
     WHERE id = p_payroll_period_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;

    IF p_kind = 'post' THEN
        IF v_p.status = 'posted' THEN
            RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p_payroll_period_id) THEN
            RAISE EXCEPTION 'NO_LINES';
        END IF;
    ELSIF p_kind = 'reversal' THEN
        IF v_p.status <> 'posted' THEN
            RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
        END IF;
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'PAYROLL_REVERSAL_REASON_REQUIRED|%', v_p.code;
        END IF;
    ELSE
        RAISE EXCEPTION 'PAYROLL_REQUEST_KIND_UNKNOWN|%|%', v_p.code, COALESCE(p_kind, '?');
    END IF;

    IF EXISTS (SELECT 1 FROM payroll_requests r
                WHERE r.payroll_period_id = p_payroll_period_id AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_OPEN|%', v_p.code;
    END IF;

    -- ★ ROLE-1 Batch 3a(Q12):提单人之外没人批得动 → 按名拒(审批关着时不拒)。
    PERFORM assert_other_decider('payroll_request', 'decide_payroll_request', 2::smallint,
                                 'PAYROLL_NO_OTHER_DECIDER|' || v_p.code);

    SELECT count(*) + 1 INTO v_n FROM payroll_requests
     WHERE payroll_period_id = p_payroll_period_id AND kind = p_kind;
    v_label := v_p.code || ' · ' || p_kind || ' #' || v_n::text;

    INSERT INTO payroll_requests (id, payroll_period_id, kind, status, label, snapshot,
                                  currency, fx_rate, gross_total, amount_base, notes, created_by)
    VALUES (v_id, p_payroll_period_id, p_kind,
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            v_label, payroll_period_fingerprint(p_payroll_period_id),
            v_p.currency, v_p.fx_rate, v_p.gross_total, round(v_p.gross_total * v_p.fx_rate, 2),
            NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    PERFORM payroll_request_dry_run(v_id);

    IF v_on THEN
        PERFORM record_approval_decision('payroll_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payroll_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'label', v_label,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$
;
