-- db/functions/claim_receipt_limits.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1):收据的上限,给页面印出来与给浏览器先判一遍用 —— 判据只有一份,在库里(claim_receipt_begin
--   读的同两列,与门户同一个数);这一支只是把那个数【说出来】,不另写一份。account_settings 对员工不可读,所以经这一支。
--   set = 两列都给了;max_bytes / types 原样。没有登录的调用者(auth.uid() 为空)读到 NULL。EXECUTE 授 authenticated。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_limits()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object('set', a.portal_upload_max_bytes IS NOT NULL AND a.portal_upload_types IS NOT NULL,
                              'max_bytes', a.portal_upload_max_bytes, 'types', to_jsonb(a.portal_upload_types))
      FROM account_settings a WHERE a.id AND auth.uid() IS NOT NULL
$function$;
