-- db/functions/void_coa_internal.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q20 · Q32):作废一张已签发的分析证书 —— 只经 CFO 批准的 coa_void 申请走到这里
--   (warehouse_request_execute_internal)。voided_by = 提单人(APR-7 grilling Q6 的同一条);作废【不动】快照与字节档案一个字。
--   没有替代品:重开一张是另一个新号,签发它时由 issue_coa 链上 replaced_by_coa_id。
--   内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.void_coa_internal(p_coa_id uuid, p_reason text, p_voided_by uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    UPDATE certificates_of_analysis
       SET status = 'void', void_reason = p_reason,
           voided_at = clock_timestamp(), voided_by = COALESCE(p_voided_by, auth.uid())
     WHERE id = p_coa_id AND status = 'issued';
END;
$function$
