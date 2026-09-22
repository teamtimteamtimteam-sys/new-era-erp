CREATE OR REPLACE FUNCTION public.guard_finance_settings_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'HISTORY_APPEND_ONLY';
END;
$function$;