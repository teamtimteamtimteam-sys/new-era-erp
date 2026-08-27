CREATE OR REPLACE FUNCTION public.next_expense_claim_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('expense_claim_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM expense_claims WHERE code LIKE 'CLM-' || v_year::text || '-%';
    RETURN 'CLM-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$

;
