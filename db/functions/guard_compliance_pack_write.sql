-- db/functions/guard_compliance_pack_write.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q16):【冻下来的合规包不改】—— compliance_packs 的删对谁都按名拒;改只许一件事:
--   一份还没被取代的包【被取代】(superseded_at / superseded_by / superseded_reason 从空到有,别的一列都不动)——
--   freeze_compliance_pack 为同一个月出 -2 时那一步。其余一律 COMPLIANCE_PACK_IMMUTABLE|<动作>。旧的 payload 因此一个字不动。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.guard_compliance_pack_write()
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
    RAISE EXCEPTION 'COMPLIANCE_PACK_IMMUTABLE|%', lower(TG_OP);
END;
$function$
