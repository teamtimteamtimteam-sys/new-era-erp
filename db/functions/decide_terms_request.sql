-- db/functions/decide_terms_request.sql
-- APR-8(2026-09-26):CFO 批准或驳回一张条款申请(公式新建 / 修改 / 重新启用 · 合同生效)。批准【当场生效】。
--
-- 【门】module.pricing.view + data.view_prices + data.view_purchase_prices + module.suppliers.view +
-- module.customers.view(grilling Q4,四种一个门)—— 看得见公式与它两个方向的价格、两侧的合同;【不是】
-- module.pricing.edit / action.contract_terms:那是提单的码。cfo 五个都持。
-- 【谁能批】二级审批人,每一张、不分档。【四眼】forbid_self_approval(提单人, NULL, …)按人认。
-- 【批准之前不另查】批准就是那一次真的生效:fingerprint 变了(TERMS_CHANGED_SINCE_REQUEST)、公式被删、合同不再是
-- 草稿 / 暂停 —— 全按原话拒,整笔回滚,申请仍在等;CFO 驳回,或 cco 撤回。驳回要理由,从不检查这些。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_terms_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    terms_requests%ROWTYPE;
    v_exec jsonb;
BEGIN
    PERFORM require_permission('module.pricing.view');
    PERFORM require_permission('data.view_prices');
    PERFORM require_permission('data.view_purchase_prices');
    PERFORM require_permission('module.suppliers.view');
    PERFORM require_permission('module.customers.view');

    SELECT * INTO v_r FROM terms_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TERMS_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'TERMS_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'terms_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'TERMS_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE terms_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('terms_request', p_request_id, 'rejected', 2::smallint, btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_exec := terms_request_execute_internal(p_request_id);

    UPDATE terms_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(), executed_at = now(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), '')
     WHERE id = p_request_id;
    PERFORM record_approval_decision('terms_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'kind', v_r.kind, 'result', v_exec);
END;
$function$;
