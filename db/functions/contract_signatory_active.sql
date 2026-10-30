-- db/functions/contract_signatory_active.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · Q3):调用者此刻在不在签署人名单上(contract_signatories 里有他员工档案的一行、没被移除)。
--   公司印章的读策略、signing-assets 的存储判据与签字 / 作废的那几支函数问的都是这一句 —— 单独一支,不内联。
--   SECURITY DEFINER:名单对普通读者只露自己那一行,而这里也只问"我自己"。没有员工档案的会话 → false。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_signatory_active()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(EXISTS (SELECT 1 FROM contract_signatories s
                             WHERE s.employee_id = current_user_employee() AND s.removed_at IS NULL), false);
$function$;
