-- db/functions/decision_gate_code.sql
-- SYSTEM-MAP-2(2026-10-27):不走审批引擎的那几种决定,各自的【权限门】—— 待办与提醒按它问"我批得了吗"。
--   链上的(采购单 · 报销 · 十种 CFO 级申请)不在这里:它们的门住在 approval_chain_gates,人住在 approval_deciders;
--   调薪与考核按人路由(pay_decision_code / review_approval_code),也不在这里。
--   这里每一个码与那一支决定函数开头的 require_permission 逐字相同;两边不许分开 ——
--   ★ 钉住它的是 fixture 302(每一种 × 七个线上角色:列在待办上 ⇔ 那一支真的决定函数接受),不是这段注释。
--   supplier 的码取自 supplier_status_moves()(pending_review → approved 那一行),不在这里另写。
-- 未知的种类返回 NULL(has_permission(NULL) 为假 —— 不认识的门关着)。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.decision_gate_code(p_item_type text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_item_type
        WHEN 'leave_request'      THEN 'action.decide_hr_requests'   -- decide_leave_request
        WHEN 'medical_claim'      THEN 'action.decide_hr_requests'   -- decide_medical_claim
        WHEN 'overtime_batch'     THEN 'action.overtime_approve'     -- decide_overtime_batch
        WHEN 'ncr'                THEN 'action.ncr_decide'           -- decide_ncr
        WHEN 'work_order'         THEN 'action.wo_release'           -- release_work_order
        WHEN 'blending_plan'      THEN 'action.wo_release'           -- release_blending_plan
        WHEN 'capture_draft'      THEN 'action.confirm_capture'      -- confirm_capture_draft / reject_capture_draft
        WHEN 'portal_certificate' THEN 'module.suppliers.edit'       -- portal_submission_accept / portal_submission_reject
        WHEN 'payment_to_pay'     THEN 'module.finance.edit'         -- pay_payment_request
        WHEN 'supplier'           THEN (SELECT m.required_code FROM supplier_status_moves() m
                                         WHERE m.from_status = 'pending_review' AND m.to_status = 'approved')
    END;
$function$;

COMMENT ON FUNCTION public.decision_gate_code(text) IS
'SYSTEM-MAP-2:不走审批引擎的决定各自的权限门(请假 · 医疗 · 加班 · 不合格 · 工单 / 配料放行 · 采集草稿 · 门户证书 · 付款 · 供应商批准)。每个码与那一支决定函数开头的 require_permission 逐字相同,由 fixture 302 钉住(列在待办上 ⇔ 真的决定函数接受)。供应商的码取自 supplier_status_moves()。未知种类 → NULL(门关着)。';
