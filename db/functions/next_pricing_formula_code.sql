CREATE OR REPLACE FUNCTION public.next_pricing_formula_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('pricing_formula_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM pricing_formulas
    WHERE code LIKE 'PF-' || v_year::text || '-%';
    RETURN 'PF-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$

