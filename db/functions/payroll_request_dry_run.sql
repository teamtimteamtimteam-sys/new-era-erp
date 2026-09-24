-- db/functions/payroll_request_dry_run.sql
-- PAYROLL-APR-1(2026-09-24,grilling Q7):按【执行那一刻会用的同一支引擎】把一张工资申请
-- 试跑一遍,然后整个回滚 —— 分录、编号、期间状态一样都不留。
--
-- 【为什么不写一份"校验函数"】与 payment_request_dry_run 逐字同一条:考勤依据、币种、期间锁、
-- 已付的行 / CPF / 扣款,抄一份出来,写下那天一致、之后悄悄分开。试跑【就是】那一份,
-- 审批人看见的拒绝是引擎自己的原话。
--
-- 【怎么做到"整个回滚"】带 EXCEPTION 子句的块就是一个子事务。引擎跑完抛专用 SQLSTATE
-- PQ002,只接这一个 —— 引擎自己的任何拒绝(PAYROLL_ATTENDANCE_NOT_COMPLETE、PERIOD_LOCKED、
-- PAYROLL_LINES_PAID……)照常往外抛。
-- 不认识的种类按名拒(PAYROLL_REQUEST_KIND_UNKNOWN)—— PAY-REQ-1 Batch B 在付款申请上
-- 记过那个 ELSE 的教训。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.payroll_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r   payroll_requests%ROWTYPE;
    v_res jsonb;
BEGIN
    SELECT * INTO v_r FROM payroll_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    BEGIN
        CASE v_r.kind
        WHEN 'post' THEN
            v_res := post_payroll_period_internal(v_r.payroll_period_id);
        WHEN 'reversal' THEN
            v_res := unpost_payroll_period_internal(v_r.payroll_period_id, v_r.notes);
        ELSE
            RAISE EXCEPTION 'PAYROLL_REQUEST_KIND_UNKNOWN|%|%', v_r.label, v_r.kind;
        END CASE;
        RAISE EXCEPTION USING ERRCODE = 'PQ002', MESSAGE = 'PAYROLL_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ002' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$
;
