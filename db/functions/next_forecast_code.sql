CREATE OR REPLACE FUNCTION public.next_forecast_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('forecast_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM cash_forecasts WHERE code LIKE 'FCST-' || v_year::text || '-%';
    RETURN 'FCST-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$

;
