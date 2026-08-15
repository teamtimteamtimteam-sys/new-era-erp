CREATE OR REPLACE FUNCTION public.guard_quote_line_converted_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q quotes%ROWTYPE;
BEGIN
    SELECT * INTO v_q FROM quotes WHERE id = COALESCE(NEW.quote_id, OLD.quote_id);
    IF v_q.status = 'converted' THEN
        RAISE EXCEPTION 'QT_CONVERTED_IMMUTABLE|lines|%', v_q.code;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$function$

;
