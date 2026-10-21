-- db/functions/claim_receipt_remove.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q5 · Q6):【从一笔上拿掉一份收据】—— 只在单还是 submitted 时;只有能往这张单上传的人
--   (Q4:这张单说的员工,与替他提单的人)。拿掉的那一行变成 removed,谁、何时记在行上;它从单上隐去,不再算这一笔的凭据;
--   【对象留在桶里】—— 没有任何员工持存储的删除权限(Q5,与门户同一条)。决定之后(批准 / 驳回 / 撤回)谁都拿不掉(Q6)。
--   按名拒:收据不在 → CLAIM_RECEIPT_NOT_FOUND;不是你的 → CLAIM_RECEIPT_NOT_YOURS|<单号>;
--   单不在 submitted → CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|<单号>|<状态>;不是 attached → CLAIM_RECEIPT_NOT_ATTACHED|<状态>。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_remove(p_receipt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r   expense_claim_receipts%ROWTYPE;
    v_c expense_claims%ROWTYPE;
BEGIN
    SELECT * INTO r FROM expense_claim_receipts x WHERE x.id = p_receipt_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM expense_claims WHERE id = r.claim_id FOR UPDATE;
    IF NOT COALESCE(v_c.employee_id = current_user_employee() OR v_c.created_by = auth.uid(), false) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_YOURS|%', v_c.code;
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT * INTO r FROM expense_claim_receipts x WHERE x.id = p_receipt_id FOR UPDATE;
    IF r.status <> 'attached' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_ATTACHED|%', r.status;
    END IF;
    UPDATE expense_claim_receipts SET status = 'removed', removed_at = now(), removed_by = auth.uid() WHERE id = r.id;
    RETURN jsonb_build_object('id', r.id, 'state', 'removed');
END;
$function$;
