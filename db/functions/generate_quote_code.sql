CREATE OR REPLACE FUNCTION public.generate_quote_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.code IS NULL OR btrim(NEW.code) = '' THEN
        NEW.code := next_quote_code(NEW.quote_date);
    END IF;
    RETURN NEW;
END;
$function$

;
