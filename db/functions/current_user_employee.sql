CREATE OR REPLACE FUNCTION public.current_user_employee()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT e.id FROM employees e
    WHERE e.user_id = auth.uid() AND e.deleted_at IS NULL
    LIMIT 1;
$function$

