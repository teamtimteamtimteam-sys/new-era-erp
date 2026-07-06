CREATE OR REPLACE FUNCTION public.fin_next_payment_code(p_prefix text, p_date date)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('payment_code_' || p_prefix || '_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM payments
    WHERE code LIKE p_prefix || '-' || v_year::text || '-%';
    RETURN p_prefix || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$
