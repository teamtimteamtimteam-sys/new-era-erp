-- db/functions/decide_shipping_release.sql
-- APR-5b(2026-09-25):CFO 批准或驳回一张发货放行。【批准就是放行】—— 没有执行那一步(APR-5 grilling Q2):
-- 批准之后仓库就能照它发货(ship_order 问覆盖),可以分好几次发。
--
-- 【门】module.sales.view + data.view_prices(Q13)—— 订单页的门,加上看得见金额的那个码(CFO 决定时看得见
-- 敞口、额度、冻结、收了多少、逐行毛利:shipping_release_context);【不是】action.request_shipping_release:
-- 那是提单的码。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】二级审批人,每一张、不分档。
-- 【四眼】forbid_self_approval(提单人, NULL, …)—— 订单不是谁"自己的单据";提单人那条腿按人认:admin@ 提的,
-- tim@ 批不了(同一个人)—— 所以提交时就按名拒 SHIPPING_RELEASE_NO_OTHER_DECIDER。self_approval_exception
-- 不认本类型,R2 不适用。
-- 【批准时再看一眼订单】订单已经取消 / 关闭(等待期间)→ SHIPPING_RELEASE_ORDER_NOT_SHIPPABLE,申请仍在等,
-- CFO 驳回或 cco 撤回。驳回从不检查这些 —— 驳回一张坏掉的申请正是出路。驳回要理由。
-- 点名的发票行在等待期间被作废了,批准照样成立:覆盖是现算的,作废那一条自己不被覆盖(Q3)。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.decide_shipping_release(p_release_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     shipping_releases%ROWTYPE;
    v_order record;
BEGIN
    PERFORM require_permission('module.sales.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM shipping_releases WHERE id = p_release_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NOT_FOUND|%', COALESCE(p_release_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'shipping_release');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'SHIPPING_RELEASE_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE shipping_releases
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_release_id;
        PERFORM record_approval_decision('shipping_release', p_release_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('release_id', p_release_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    SELECT code, status, deleted_at INTO v_order FROM sales_orders WHERE id = v_r.sales_order_id;
    IF v_order.deleted_at IS NOT NULL OR v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_ORDER_NOT_SHIPPABLE|%|%', v_order.code, v_order.status;
    END IF;

    UPDATE shipping_releases
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), '')
     WHERE id = p_release_id;
    PERFORM record_approval_decision('shipping_release', p_release_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('release_id', p_release_id, 'label', v_r.label, 'status', 'approved');
END;
$function$
;
