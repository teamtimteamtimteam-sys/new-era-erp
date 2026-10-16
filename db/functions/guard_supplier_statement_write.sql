-- db/functions/guard_supplier_statement_write.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q7):【签发了的对账单不改】—— supplier_statements 的删对谁都按名拒;改只许一件事:
--   一份还没被取代的对账单【被取代】(superseded_at / superseded_by / superseded_reason 从空到有,别的一列都不动)——
--   issue_supplier_statement 为同一段期间出新的一份时那一步。其余一律 SUPPLIER_STATEMENT_IMMUTABLE|<动作>。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.guard_supplier_statement_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'UPDATE'
       AND OLD.superseded_at IS NULL AND NEW.superseded_at IS NOT NULL
       AND (to_jsonb(NEW) - 'superseded_at' - 'superseded_by' - 'superseded_reason')
           = (to_jsonb(OLD) - 'superseded_at' - 'superseded_by' - 'superseded_reason') THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'SUPPLIER_STATEMENT_IMMUTABLE|%', lower(TG_OP);
END;
$function$
