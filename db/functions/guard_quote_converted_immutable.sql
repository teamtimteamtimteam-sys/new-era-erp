CREATE OR REPLACE FUNCTION public.guard_quote_converted_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status = 'converted' THEN
            RAISE EXCEPTION 'QT_CONVERTED_IMMUTABLE|delete|%', OLD.code;
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.status = 'converted' THEN
        RAISE EXCEPTION 'QT_CONVERTED_IMMUTABLE|row|%', OLD.code;
    END IF;
    IF OLD.converted_order_id IS NOT NULL
       AND NEW.converted_order_id IS DISTINCT FROM OLD.converted_order_id THEN
        RAISE EXCEPTION 'QT_CONVERTED_IMMUTABLE|converted_order_id|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$

;
