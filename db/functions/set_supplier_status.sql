-- db/functions/set_supplier_status.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §6,Batch 2 grilling Q8–Q9,Batch 2a grilling Q2–Q4):
-- 供应商状态的【唯一】改法。此前没有这支函数 —— 状态面板直连 UPDATE suppliers.status,
-- 跳转触发器只管"合不合法",不管"谁可以"。
--
-- 【做什么,按顺序】
--   ① 供应商在、没被删(FOR UPDATE 锁住)→ 否则 SUPPLIER_NOT_FOUND;
--   ② 这一步在 supplier_status_moves() 里 → 否则 INVALID_STATUS_TRANSITION|从|到
--      (与触发器同一句话,因为读的是同一张表);
--   ③ require_permission(那一步要的码)—— CFO 那四类走 action.supplier_approve,其余 module.suppliers.edit;
--   ④ → approved / → rejected:**建档人永远不能批自己建的**(Q8)—— forbid_self_approval
--      按【人】认(account_person:一个人的两个账号算一个人),'supplier' 不在
--      self_approval_exception 的任何一条例外里,所以永远拒 SELF_APPROVAL_FORBIDDEN|raiser。
--      created_by 为 NULL 的供应商(线上 7 家,SOD-1 之前建的)这条不适用 —— 那是 Tim 裁过的(Q8)。
--   ⑤ UPDATE 状态;approved_by / approved_at 的盖章与清空由触发器做(Q4),
--      变动史由 trg_suppliers_status_history 记(Q3)—— 本函数把 p_note 经一个事务内的
--      设置项交给那支触发器,写完即清。
--   ⑥ approval_log:送审记 submitted、批准记 approved、驳回记 rejected(Q3);subject_type = 'supplier'。
--
-- 【它【不是】审批引擎的一条链】(Q9)不调用 require_approver_for,没有金额档位,
-- 审批开关关着也照样要 CFO 批 —— fixture 203 断言 approval_chain_gates() 等于每一支
-- 调用 require_approver_for 的函数,所以这里不许调用它。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.set_supplier_status(p_supplier_id uuid, p_to text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s    suppliers%ROWTYPE;
    v_to   supplier_status;
    v_code text;
BEGIN
    IF p_to IS NULL OR NOT (p_to = ANY (enum_range(NULL::supplier_status)::text[])) THEN
        RAISE EXCEPTION 'SUPPLIER_STATUS_UNKNOWN|%', COALESCE(p_to, '?');
    END IF;
    v_to := p_to::supplier_status;

    SELECT * INTO v_s FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
    END IF;

    SELECT m.required_code INTO v_code
      FROM supplier_status_moves() m
     WHERE m.from_status = v_s.status::text AND m.to_status = v_to::text;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'INVALID_STATUS_TRANSITION|%|%', v_s.status, v_to;
    END IF;
    PERFORM require_permission(v_code);

    IF v_to IN ('approved', 'rejected') THEN
        PERFORM forbid_self_approval(v_s.created_by, NULL, 'supplier');
    END IF;

    PERFORM set_config('evoltrya.supplier_status_note', COALESCE(NULLIF(btrim(p_note), ''), ''), true);
    UPDATE suppliers SET status = v_to, updated_by = auth.uid() WHERE id = p_supplier_id;
    PERFORM set_config('evoltrya.supplier_status_note', '', true);

    IF v_to = 'pending_review' THEN
        PERFORM record_approval_decision('supplier', p_supplier_id, 'submitted', NULL, NULLIF(btrim(p_note), ''));
    ELSIF v_to IN ('approved', 'rejected') THEN
        PERFORM record_approval_decision('supplier', p_supplier_id, v_to::text, NULL, NULLIF(btrim(p_note), ''));
    END IF;

    RETURN jsonb_build_object('code', v_s.code, 'from', v_s.status, 'to', v_to);
END;
$function$;

COMMENT ON FUNCTION public.set_supplier_status(uuid, text, text) IS
'ROLE-1 Batch 2a:供应商状态的唯一改法。每一步要的码读 supplier_status_moves()(CFO 的 action.supplier_approve 管批准 / 驳回 / 拉黑 / 拉黑后归档;其余 module.suppliers.edit)。批准与驳回按人拒自批(建档人)。送审、批准、驳回写 approval_log(subject_type = supplier);每一步都进 supplier_status_history。不是审批引擎的链:审批开关不关它。';
