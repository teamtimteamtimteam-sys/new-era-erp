CREATE OR REPLACE FUNCTION public.guard_cod_no_delete_after_issue()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'COD_NO_DELETE|%', COALESCE(OLD.code, OLD.id::text);
    END IF;
    RETURN OLD;
END;
$function$;
