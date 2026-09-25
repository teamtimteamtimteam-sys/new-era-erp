-- db/functions/decide_warehouse_request.sql
-- APR-7(2026-09-25):CFO 批准或驳回一张仓库申请(注销 · 回滚 · 证书作废)。批准【当场生效】,按批准那一天
-- (grilling Q4:流水与分录落在批准日;价值按批准那一刻的活数)。
--
-- 【门】module.finance.view + data.view_prices(grilling Q8)—— 与付款、贷项、手工凭证申请同一对码;
-- 【不是】提单的那三个 action 码。cfo 两个都持。四种一个门:证书作废不动钱,但它是同一张表、同一个决定人。
-- 【谁能批】二级审批人,每一张、不分档。【四眼】forbid_self_approval(提单人, NULL, …)按人认 ——
-- admin@ 提的 tim@ 批不了(同一个人),所以提交时就按名拒 WAREHOUSE_REQUEST_NO_OTHER_DECIDER。
--
-- 【批准之前不另查】批准就是那一次真的生效:欠款(INBOUND_HAS_OPEN_PAYABLE,Q4 的第二遍)、订单预留、
-- 产出动过、证书不再是已签发 —— 全按原话拒,整笔回滚,申请仍在等;CFO 驳回,或仓库撤回。冻结
-- (guard_warehouse_request_freeze)让这些在等待中几乎不会发生。驳回要理由,从不检查这些。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_warehouse_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    warehouse_requests%ROWTYPE;
    v_exec jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM warehouse_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'warehouse_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'WAREHOUSE_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE warehouse_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('warehouse_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_exec := warehouse_request_execute_internal(p_request_id);

    UPDATE warehouse_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(), executed_at = now(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           amount_base = (v_exec->>'amount_base')::numeric,
           result_entry_ids = ARRAY(SELECT jsonb_array_elements_text(v_exec->'entry_ids')::uuid)
     WHERE id = p_request_id;
    PERFORM record_approval_decision('warehouse_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'kind', v_r.kind, 'amount_base', v_exec->'amount_base',
                              'entry_ids', v_exec->'entry_ids');
END;
$function$;
