CREATE OR REPLACE FUNCTION public.has_permission(p_code text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT p_code = ANY (current_user_permissions());
$function$

