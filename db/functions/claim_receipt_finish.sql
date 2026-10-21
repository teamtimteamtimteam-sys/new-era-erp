-- db/functions/claim_receipt_finish.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1 · Q12):【一份收据的字节到了】—— 确认对象在桶里、大小与类型与登记的那一行对得上,
--   这一行变成 attached(从此算这一笔的凭据)。MES-9c portal_submission_finish 的形状。
--   按名拒:不是自己登记的 → CLAIM_RECEIPT_NOT_FOUND;登记的人此刻已不是这张单的人(Q4)→ CLAIM_RECEIPT_NOT_YOURS|<单号>;不在 uploading → CLAIM_RECEIPT_NOT_UPLOADING|<状态>;
--   单已不是 submitted(上传途中被批 / 驳回 / 撤回)→ CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|<单号>|<状态>;
--   对象不在 → CLAIM_RECEIPT_NOT_STORED;大小或类型对不上 → CLAIM_RECEIPT_MISMATCH。
--   【文件头】库读不到字节:按文件头认类型的那一步在调用它的服务端动作里(app/me/claimReceiptActions.ts),
--   认不出或与登记的类型不同 → 那一步调 claim_receipt_abandon 而不是这一支。
--   单行锁上报销单(FOR UPDATE),与 decide_expense_claim_items 的锁同一行 —— 一份收据要么在决定之前到,要么就不算。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_finish(p_receipt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r      expense_claim_receipts%ROWTYPE;
    v_c    expense_claims%ROWTYPE;
    v_meta jsonb;
BEGIN
    SELECT * INTO r FROM expense_claim_receipts x WHERE x.id = p_receipt_id AND x.created_by = auth.uid();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM expense_claims WHERE id = r.claim_id FOR UPDATE;
    -- 登记它的人此刻仍是这张单的人(Q4)—— 与 begin 同一条
    IF NOT COALESCE(v_c.employee_id = current_user_employee() OR v_c.created_by = auth.uid(), false) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_YOURS|%', v_c.code;
    END IF;
    SELECT * INTO r FROM expense_claim_receipts x WHERE x.id = p_receipt_id FOR UPDATE;
    IF r.status <> 'uploading' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_UPLOADING|%', r.status;
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT COALESCE(o.metadata, '{}'::jsonb) INTO v_meta FROM storage.objects o WHERE o.bucket_id = r.bucket_id AND o.name = r.storage_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_STORED';
    END IF;
    IF (v_meta ? 'size' AND (v_meta ->> 'size')::bigint <> r.file_size)
       OR (v_meta ? 'mimetype' AND v_meta ->> 'mimetype' <> r.file_type) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_MISMATCH';
    END IF;
    UPDATE expense_claim_receipts SET status = 'attached', attached_at = now() WHERE id = r.id;
    RETURN jsonb_build_object('id', r.id, 'state', 'attached');
END;
$function$;
