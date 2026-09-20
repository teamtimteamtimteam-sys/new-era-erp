CREATE OR REPLACE FUNCTION public.guard_fixed_asset_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'FA_HISTORY_IMMUTABLE';
END;
$function$
