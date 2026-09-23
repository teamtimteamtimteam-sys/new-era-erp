-- db/functions/decide_payment_request.sql
-- PAY-REQ-1(2026-09-23):CFO 批准或驳回一张付款申请。
--
-- ★ Tim 的矩阵:付款、冲销付款 —— 财务提,CFO 批,【每一张都批,没有金额门槛】。
--   所以这里直接要二级:PERFORM require_approver_for(2),【不】经 approval_level_for。
--   二级是哪个角色仍然只从 finance_settings.approval_level2_role_code 读 ——
--   路由的定义没有第二份。approval_level_eligible 只把二级持有人加进一级,
--   从不反过来,所以一级持有人批不了这里。
--   ☞ 这一条链在 approval_chain_gates 里【只有二级那一行】,
--     approval_pending_documents 里带 fixed_level = 2 ——
--     APPROVALS_POLICY_WOULD_STRAND 于是不会按金额把一张小额申请错分到一级、
--     再因为"一级没有这条链的名册行"而悄悄放过(PAY-REQ-1 grilling 找到的那个坑)。
--
-- ★ 门:module.finance.view + data.view_prices —— 与报销单同一对码(APR-3 的理由原样成立:
--   ① 批的人不该是提得了这张单的人,edit 就是提单那个码;② R4,批的人要看得见他批的数)。
--
-- ★ 提单人永远不能批:forbid_self_approval(按人认,经 self_leg)。主角是【收款员工】
--   (付给员工时):CFO 批不了付给他自己的钱。self_approval_exception 只认报销单、
--   医疗申报、请假三类,'payment_request' 不在里面 —— 于是这里【没有】例外。
--
-- ★ 审批关着时这支函数按名拒(APPROVALS_NOT_ENABLED):关着时申请生下来就是 approved,
--   不会有 submitted 的申请等它;而关闭那道闸(blocks_disable = true)保证了
--   有申请在等时关不掉。与 approve_purchase_order 同形。
--
-- ★ 批准前再核一遍(Tim 的 Q4):收款人没被拉黑/暂停;按引擎试跑一遍(被作废的单、
--   已被别的路径付掉的单、关了的期间,都在这里按原话拒 —— CFO 看得见为什么批不了,
--   驳回它即可)。驳回不核:驳回一张坏掉的申请正是出路。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.decide_payment_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r payment_requests%ROWTYPE;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM payment_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_SUBMITTED|%|%', v_r.code, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, v_r.employee_id, 'payment_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'PAYMENT_REQUEST_REJECT_REASON_REQUIRED|%', v_r.code;
        END IF;
        UPDATE payment_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('payment_request', p_request_id, 'rejected',
                                         2::smallint, btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'code', v_r.code, 'status', 'rejected');
    END IF;

    PERFORM payment_request_payee_check(v_r.kind, v_r.supplier_id);
    PERFORM payment_request_dry_run(p_request_id);

    UPDATE payment_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), '')
     WHERE id = p_request_id;
    PERFORM record_approval_decision('payment_request', p_request_id, 'approved',
                                     2::smallint, NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_r.code, 'status', 'approved');
END;
$function$
;
