-- db/functions/guard_supplier_scorecard_review_write.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q2):【一次评审记下就不改】—— supplier_scorecard_reviews 的改与删对谁都按名拒(连属主、连 postgres 之外的
--   每一条路;RLS 在会话里本来就没有写策略,这一支管的是绕得过 RLS 的那条路 —— fixture 195 记过同一件事)。
--   记错了的评审由一次【引用它、写明理由】的新评审更正(record_supplier_review 的 p_corrects_review_id)。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.guard_supplier_scorecard_review_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'SUPPLIER_REVIEW_IMMUTABLE|%', lower(TG_OP);
END;
$function$
