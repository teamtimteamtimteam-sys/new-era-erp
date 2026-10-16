-- db/functions/guard_compliance_pack_issue_write.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q16):【签发档只追加】—— compliance_pack_issues 的改与删对谁都按名拒。一份存下的 PDF 就是交出去过的那一份;
--   重新渲染 = 新的一版(record_compliance_pack_issue),绝不覆盖旧行。自己报名(一句写着别的单据的拒绝在合规包上是一句假话)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.guard_compliance_pack_issue_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'COMPLIANCE_PACK_ISSUE_IMMUTABLE|%', lower(TG_OP);
END;
$function$
