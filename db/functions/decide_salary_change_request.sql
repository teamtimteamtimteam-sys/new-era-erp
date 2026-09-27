-- db/functions/decide_salary_change_request.sql
-- APR-9(2026-09-27):批准或驳回一张调薪申请。批准【当场生效】(salary_change_execute_internal)。
--
-- 【门】module.hr.view + data.view_pay(批的人看得见他批的那个数,§5),再加 pay_decision_code(提单人, 员工):
--   CFO → action.approve_review;CFO 这个人是提单人或主角 → action.hr_reviews(cco)。与绩效评估同一份判据(Q2)。
--   【不是】module.hr.edit —— 那是提单的码。
-- 【四眼】forbid_self_approval(提单人, 员工, 'salary_change_request'):提单人与主角都不能批,按人认;
--   R2 的自批例外不认这个类型,所以永远没有"自批加薪"。
-- 【不看审批开关】(Q3)开着关着都批得了 —— 所以它在 approval_pending_documents 里 blocks_disable = false,
--   也【不】调用 require_approver_for(那一支属于按级的名册,db/fixtures/203 E 按调用者数它)。
-- 驳回要理由,从不检查 fingerprint 与生效日。留痕:approved / rejected,level NULL。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.decide_salary_change_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    salary_change_requests%ROWTYPE;
    v_code text;
    v_exec jsonb;
BEGIN
    PERFORM require_permission('module.hr.view');
    PERFORM require_permission('data.view_pay');

    SELECT * INTO v_r FROM salary_change_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    -- 谁批得了要先读到这一行才答得出(approve_review 同序)
    v_code := pay_decision_code(v_r.created_by, v_r.employee_id);
    PERFORM require_permission(v_code);
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    PERFORM forbid_self_approval(v_r.created_by, v_r.employee_id, 'salary_change_request');

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'SALARY_CHANGE_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE salary_change_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(), decided_via = v_code,
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('salary_change_request', p_request_id, 'rejected', NULL, btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_exec := salary_change_execute_internal(p_request_id);

    UPDATE salary_change_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(), decided_via = v_code,
           executed_at = now(), decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), '')
     WHERE id = p_request_id;
    PERFORM record_approval_decision('salary_change_request', p_request_id, 'approved', NULL,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'decided_via', v_code, 'effective_date', v_r.effective_date,
                              'employee_code', v_exec->>'employee_code');
END;
$function$;
