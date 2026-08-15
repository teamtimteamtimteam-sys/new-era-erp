CREATE OR REPLACE FUNCTION public.trg_quote_history_created()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    INSERT INTO quote_history (quote_id, change_type, detail, changed_by)
    VALUES (NEW.id, 'created', NEW.code, NEW.created_by);
    RETURN NEW;
END;
$function$

;
