-- db/functions/unpost_payroll_period.sql
-- 撤销工资过账的【外门】—— PAYROLL-APR-1(2026-09-24)起,它只执行一张【已批准】的撤销申请。
--
-- Tim 的矩阵 §5:工资过账的撤销,财务做,CFO 批每一张、不分档(grilling Q3)。
--   ① 仍要 module.hr.edit;
--   ② 找【这个期间、kind = 'reversal'、status = 'approved'】的那一张 —— 没有就按名拒
--      PAYROLL_NEEDS_APPROVED_REQUEST|<期间编号>|reversal;
--   ③ 批的那一组数与此刻的数再比一次(PAYROLL_CHANGED_SINCE_REQUEST);
--   ④ 交给引擎 unpost_payroll_period_internal,理由取【申请上】那一句 —— CFO 批的就是它,
--      执行的人不另给一句。所以签名从 (uuid, text) 改成了 (uuid):一个会被忽略的参数,
--      比一个不存在的参数更会骗人。
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql; the door shape by
--       db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.unpost_payroll_period(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p   payroll_periods%ROWTYPE;
    v_r   payroll_requests%ROWTYPE;
    v_je  uuid;
    v_res jsonb;
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

    SELECT * INTO v_r FROM payroll_requests
     WHERE payroll_period_id = p_id AND kind = 'reversal' AND status = 'approved'
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NEEDS_APPROVED_REQUEST|%|reversal', v_p.code;
    END IF;
    IF payroll_period_fingerprint(p_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'PAYROLL_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    v_res := unpost_payroll_period_internal(p_id, v_r.notes);

    SELECT reversed_by INTO v_je FROM journal_entries WHERE id = v_p.journal_entry_id;
    UPDATE payroll_requests
       SET status = 'executed', executed_at = now(), executed_by = auth.uid(),
           result_journal_entry_id = v_je
     WHERE id = v_r.id;

    RETURN v_res || jsonb_build_object('request_id', v_r.id, 'request_label', v_r.label);
END;
$function$
;
