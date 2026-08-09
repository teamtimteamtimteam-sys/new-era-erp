CREATE OR REPLACE FUNCTION public.approvals_enabled()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((SELECT approvals_enabled FROM finance_settings LIMIT 1), false);
$function$;