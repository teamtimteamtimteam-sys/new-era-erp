CREATE OR REPLACE FUNCTION public.guard_pricing_formula_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'HISTORY_APPEND_ONLY';
END;
$function$;