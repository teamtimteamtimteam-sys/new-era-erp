-- db/functions/decide_asset_disposal_request.sql
-- APR-9(2026-09-27):CFO 批准或驳回一张固定资产处置申请。批准【当场处置】,处置日 = 批准那一天,
-- 累计折旧与损益按那一刻的活数(grilling Q7)。
--
-- 【门】module.finance.view + data.view_prices(Q10:APR-7 同一对码)—— 【不是】module.finance.edit:那是提单的码。
-- 【谁能批】二级审批人,每一张、不分档(require_approver_for(2))。【四眼】forbid_self_approval(提单人, NULL, …)
-- 按人认 —— 一台资产是公司的,主角那条腿对谁都不成立(工单同形);admin@ 提的 tim@ 批不了,所以提交时就按名拒
-- ASSET_DISPOSAL_NO_OTHER_DECIDER。
-- 【批准之前不另查】批准就是那一次真的处置:卡变了(ASSET_CHANGED_SINCE_REQUEST)、期间锁(PERIOD_LOCKED)——
-- 全按原话拒,整笔回滚,申请仍在等。驳回要理由,从不检查这些。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.decide_asset_disposal_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    asset_disposal_requests%ROWTYPE;
    v_exec jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM asset_disposal_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'asset_disposal_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'ASSET_DISPOSAL_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE asset_disposal_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('asset_disposal_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_exec := asset_disposal_execute_internal(p_request_id);

    UPDATE asset_disposal_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(), executed_at = now(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           disposal_date = (v_exec->>'disposal_date')::date,
           result_entry_id = (v_exec->>'entry_id')::uuid, result = v_exec,
           amount_base = (v_exec->>'amount_base')::numeric
     WHERE id = p_request_id;
    PERFORM record_approval_decision('asset_disposal_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'result', v_exec);
END;
$function$;
