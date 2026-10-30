-- db/functions/signing_asset_can_read.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q3 · Q4):【存储策略的判据】—— 这个会话能不能读 signing-assets 里的这一个对象。
--   specimens/<员工 id>/… —— 只有本人(签字时服务端以本人的会话取它;admin 看得到"有没有样本",看不到那张图);
--   stamps/…            —— 持 action.manage_signatories 的人,与此刻在签署人名单上的人(签字页预览、服务端盖章)。【绝不抛】。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.signing_asset_can_read(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'signing-assets'
       AND ((current_user_employee() IS NOT NULL AND p_name LIKE 'specimens/' || current_user_employee()::text || '/%')
         OR (p_name LIKE 'stamps/%' AND (has_permission('action.manage_signatories') OR contract_signatory_active()))), false)
$function$;
