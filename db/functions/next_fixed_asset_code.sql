CREATE OR REPLACE FUNCTION public.next_fixed_asset_code(p_on date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_on)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('fixed_asset_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(fa.code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM fixed_assets fa
    WHERE fa.code LIKE 'FA-' || v_year::text || '-%';
    RETURN 'FA-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;
