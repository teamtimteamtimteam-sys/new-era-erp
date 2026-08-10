CREATE OR REPLACE FUNCTION public.has_any_permission(p_codes text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (SELECT 1 FROM unnest(p_codes) c WHERE has_permission(c));
$function$;