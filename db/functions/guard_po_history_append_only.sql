CREATE OR REPLACE FUNCTION public.guard_po_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'PO_HISTORY_APPEND_ONLY|%', TG_OP;
END;
$function$;