-- db/functions/withdraw_payroll_request.sql
-- PAYROLL-APR-1(2026-09-24):撤回一张工资申请。submitted 与 approved 都可以撤回
-- (PAY-REQ-1 的第 1 条:一张执行不了的申请不许永远占着它的期间 —— 而申请开着时
-- 那个期间不许保存、那个月的考勤不许重开,撤回就是回去改的那条路)。
-- 撤回不过账,只是放弃;executed / rejected / withdrawn 不能撤。
-- 谁能撤:财务(module.hr.edit)—— 提单人本来就持这个码。
-- 不写 approval_log:撤回不是一次【决定】(与付款申请、报销单的撤回同一条)。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.withdraw_payroll_request(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r payroll_requests%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_r FROM payroll_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status NOT IN ('submitted', 'approved') THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE payroll_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid()
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$
;
