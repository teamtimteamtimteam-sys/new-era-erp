CREATE OR REPLACE FUNCTION public.guard_document_tax_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.tax_code IS NOT NULL AND NOT gst_registered() THEN
        RAISE EXCEPTION 'GST_NOT_REGISTERED|%', NEW.tax_code;
    END IF;
    RETURN NEW;
END;
$function$
;