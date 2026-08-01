-- db/functions/next_medical_claim_code.sql
-- 无缝编号 MC-YYYY-NNNN。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.next_medical_claim_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('medical_claim_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM medical_claims WHERE code LIKE 'MC-' || v_year::text || '-%';
    RETURN 'MC-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;
