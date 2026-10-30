-- db/functions/signing_asset_can_upload.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q3 · Q4):【存储策略的判据】—— 这个会话能不能往 signing-assets 的这一条路径传字节。
--   specimens/<自己的员工 id>/<uuid>.png —— 只有【本人】、而且此刻在签署人名单上(Q4:admin 替别人设不了签名);
--   stamps/<uuid>.png                  —— 只有持 action.manage_signatories 的人(Q3)。
--   一条已经被登记过的路径不再收(signature_specimens / company_stamps 里有它)。改与删没有策略。【绝不抛】,不成立就回 false。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.signing_asset_can_upload(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_bucket = 'signing-assets'
       AND ((p_name ~ ('^specimens/' || current_user_employee()::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$')
             AND contract_signatory_active()
             AND NOT EXISTS (SELECT 1 FROM signature_specimens s WHERE s.file_path = p_name))
         OR (p_name ~ '^stamps/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.png$'
             AND has_permission('action.manage_signatories')
             AND NOT EXISTS (SELECT 1 FROM company_stamps s WHERE s.file_path = p_name))), false)
$function$;
