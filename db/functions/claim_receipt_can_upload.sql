-- db/functions/claim_receipt_can_upload.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q4):【存储策略的判据】—— 这个会话能不能往 claim-receipts 的这一条路径传字节(与读回它刚传的那一行)。
--   成立 = 有一行 status = uploading 的收据,路径正是这一条、是【这个会话自己】在十分钟内登记的、它的单仍是 submitted、
--   而这个会话此刻仍是那张单的人(说的那名员工,或替他提单的人 —— Q4)
--   —— 那一行只由 claim_receipt_begin 在判过调用者、单的状态、上限与存储余量之后写。于是:没先过 begin 的字节存不进来;
--   别人的路径、已经传完的、过了十分钟的、单已经被决定或撤回的,一律存不进来。改与删没有策略。
--   MES-9c portal_can_upload_object 的形状,换成 auth.uid()。【绝不抛】在 RLS 里抛会把一次上传变成一次 500;不成立就回 false。
--   EXECUTE 授 authenticated(策略以调用者身份求值)。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_can_upload(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'claim-receipts'
       AND EXISTS (SELECT 1 FROM expense_claim_receipts r JOIN expense_claims c ON c.id = r.claim_id
                    WHERE r.storage_path = p_name AND r.status = 'uploading' AND r.created_by = auth.uid()
                      AND r.created_at > now() - interval '10 minutes' AND c.status = 'submitted'
                      AND (c.employee_id = current_user_employee() OR c.created_by = auth.uid())), false)
$function$;
