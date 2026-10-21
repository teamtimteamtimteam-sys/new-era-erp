-- db/functions/claim_receipt_abandon.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q12):【一份收据没传成】—— 自己登记的、还在 uploading 的那一行变成 abandoned。
--   传字节失败、或服务端按文件头认出类型不对时,由服务端动作调它。桶里若已留下字节,它们留着 —— 没有删除策略(Tim 2026-10-21 Q5:
--   没有任何员工持存储的删除权限;与门户那一份的裁定同形,Tim 2026-10-20 d2 #3:字节留着,不建清理路径)。
--   按名拒:不是自己登记的 → CLAIM_RECEIPT_NOT_FOUND;登记的人此刻已不是这张单的人 → CLAIM_RECEIPT_NOT_YOURS|<单号>;不在 uploading → CLAIM_RECEIPT_NOT_UPLOADING|<状态>。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_abandon(p_receipt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status text;
BEGIN
    SELECT x.status INTO v_status FROM expense_claim_receipts x WHERE x.id = p_receipt_id AND x.created_by = auth.uid() FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_FOUND';
    END IF;
    -- 登记它的人此刻仍是这张单的人(Q4)—— 与 begin 同一条
    IF NOT EXISTS (SELECT 1 FROM expense_claim_receipts x JOIN expense_claims c ON c.id = x.claim_id
                    WHERE x.id = p_receipt_id AND (c.employee_id = current_user_employee() OR c.created_by = auth.uid())) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_YOURS|%', (SELECT c.code FROM expense_claim_receipts x JOIN expense_claims c ON c.id = x.claim_id WHERE x.id = p_receipt_id);
    END IF;
    IF v_status <> 'uploading' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_UPLOADING|%', v_status;
    END IF;
    UPDATE expense_claim_receipts SET status = 'abandoned' WHERE id = p_receipt_id;
    RETURN jsonb_build_object('id', p_receipt_id, 'state', 'abandoned');
END;
$function$;
