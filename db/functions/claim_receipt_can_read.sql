-- db/functions/claim_receipt_can_read.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q6 · Q7):【存储策略的判据】—— 这个会话能不能读 claim-receipts 里的这一个对象。
--   成立 = 持 module.finance.view(Q7:admin · cco · cfo · cto · finance · gm 读每一名员工的收据,Tim 接受),
--        或者这个对象是一行收据的路径,而那张单说的是【你】、或者是【你】替人提的(Q6:决定之后照样读得到);
--        或者它正是你刚登记、还在上传的那一条(Storage API 插入之后读回那一行要它 —— 与 claim_receipt_can_upload 同一条)。
--   一份被拿掉(removed)的收据:员工与提单人不再读到它(Q5:从单上隐去);财务照样读得到(对象留在桶里,留痕的一部分)。
--   【绝不抛】;EXECUTE 授 authenticated。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_can_read(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'claim-receipts'
       AND (has_permission('module.finance.view')
            OR EXISTS (SELECT 1 FROM expense_claim_receipts r JOIN expense_claims c ON c.id = r.claim_id
                        WHERE r.storage_path = p_name
                          AND (r.status = 'attached' OR (r.status = 'uploading' AND r.created_by = auth.uid()))
                          AND (c.employee_id = current_user_employee() OR c.created_by = auth.uid()))), false)
$function$;
