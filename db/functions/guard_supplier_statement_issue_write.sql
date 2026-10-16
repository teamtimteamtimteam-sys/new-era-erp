-- db/functions/guard_supplier_statement_issue_write.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q9):【签发档只追加】—— supplier_statement_issues 的改与删对谁都按名拒。一份存下的 PDF 就是寄出去过的那一份;
--   重新渲染 = 新的一版(record_supplier_statement_issue),绝不覆盖旧行。自己报名(不借贷项凭证那一支 —— 一句写着 CREDIT_NOTE 的拒绝
--   在对账单上是一句假话)。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.guard_supplier_statement_issue_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'SUPPLIER_STATEMENT_ISSUE_IMMUTABLE|%', lower(TG_OP);
END;
$function$
