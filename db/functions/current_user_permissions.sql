CREATE OR REPLACE FUNCTION public.current_user_permissions()
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(array_agg(DISTINCT rp.permission_code), ARRAY[]::text[])
    FROM user_roles ur
    JOIN roles r ON r.id = ur.role_id
    JOIN role_permissions rp ON rp.role_id = r.id
    WHERE ur.user_id = auth.uid()
      AND ur.revoked_at IS NULL
      AND r.is_active
      AND r.deleted_at IS NULL;
$function$

