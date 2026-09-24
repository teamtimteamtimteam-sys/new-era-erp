-- db/functions/post_payroll_period.sql
-- 工资过账的【外门】—— PAYROLL-APR-1(2026-09-24)起,它只执行一张【已批准】的过账申请。
--
-- Tim 的矩阵 §5:工资过账,财务做,CFO 批每一张、不分档;**批之前什么都不过账**(grilling Q3)。
-- 所以这支函数:
--   ① 仍要 module.hr.edit(做的人是财务,与从前同一个码);
--   ② 找【这个期间、kind = 'post'、status = 'approved'】的那一张申请 —— 没有就按名拒
--      PAYROLL_NEEDS_APPROVED_REQUEST|<期间编号>|post。审批关着时申请生下来就是 approved,
--      所以关着的时候这条路照样走得通,只是多了一张 auto_approved 的申请;
--   ③ 批的那一组数与此刻的数再比一次(PAYROLL_CHANGED_SINCE_REQUEST);
--   ④ 交给引擎 post_payroll_period_internal(考勤、币种、分录、期间锁原样),
--      把申请标成 executed 并记下那张分录。
-- 执行的人可以就是提单人(PAY-REQ-1 的 Q3:四眼在"提"与"批"之间)。
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql; the door shape by
--       db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.post_payroll_period(p_payroll_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p   payroll_periods%ROWTYPE;
    v_r   payroll_requests%ROWTYPE;
    v_res jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM payroll_periods
     WHERE id = p_payroll_period_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status = 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
    END IF;

    SELECT * INTO v_r FROM payroll_requests
     WHERE payroll_period_id = p_payroll_period_id AND kind = 'post' AND status = 'approved'
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NEEDS_APPROVED_REQUEST|%|post', v_p.code;
    END IF;
    IF payroll_period_fingerprint(p_payroll_period_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'PAYROLL_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    v_res := post_payroll_period_internal(p_payroll_period_id);

    UPDATE payroll_requests
       SET status = 'executed', executed_at = now(), executed_by = auth.uid(),
           result_journal_entry_id = (SELECT journal_entry_id FROM payroll_periods WHERE id = p_payroll_period_id)
     WHERE id = v_r.id;

    RETURN v_res || jsonb_build_object('request_id', v_r.id, 'request_label', v_r.label);
END;
$function$
;
