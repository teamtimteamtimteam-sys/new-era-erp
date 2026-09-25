-- db/functions/decide_invoice_request.sql
-- APR-5a(2026-09-25):CFO 批准或驳回一张贷项 / 作废申请。批准【当场过账】(grilling Q9),按提交时冻下来的
-- 那一组参数 —— 日期就是提单人填的那一天。
--
-- 【门】module.finance.view + data.view_prices —— 与付款申请同一对码(发票页的门,加上看得见金额的那个码;
-- docs/approvals.md §5)。【不是】module.finance.edit:那是提单的码。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】二级审批人,每一张、不分档,从不经按金额分档的那一支。
-- 【四眼】forbid_self_approval(提单人, NULL, …)—— 发票不是谁的"自己的单据",主角那条腿对谁都不成立;
-- 提单人那条腿按人认:admin@ 提的,tim@ 批不了(同一个人)—— 所以提交时就按名拒
-- INVOICE_REQUEST_NO_OTHER_DECIDER,不让它挂到这里。self_approval_exception 不认本类型,R2 不适用。
--
-- 【批准之前不另查】等待期间发票能变的只有收款(Q10:收款从不被挡)。批准就是那一次真的过账:
-- 超出开放余额、已结清、有核销、已发货、有贷项、期间锁 —— 全按引擎原话拒,整笔回滚,申请仍在等;
-- CFO 驳回,或财务撤回再提。驳回从不检查这些:驳回一张坏掉的申请,正是出路。驳回要理由。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_invoice_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    invoice_requests%ROWTYPE;
    v_post jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM invoice_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'INVOICE_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'invoice_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'INVOICE_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE invoice_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('invoice_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_post := invoice_request_post_internal(p_request_id);

    UPDATE invoice_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           amount_base = (v_post->>'amount_base')::numeric,
           result_credit_note_id = (v_post->>'credit_note_id')::uuid,
           result_journal_entry_id = (v_post->>'entry_id')::uuid
     WHERE id = p_request_id;
    PERFORM record_approval_decision('invoice_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'kind', v_r.kind,
                              'credit_note_code', CASE WHEN v_r.kind = 'credit_note' THEN v_post->>'code' END,
                              'journal_code', COALESCE(v_post->>'journal_code', v_post->>'reversal_code'),
                              'amount_base', v_post->'amount_base');
END;
$function$
;