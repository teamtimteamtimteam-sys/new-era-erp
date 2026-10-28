-- LOCAL TIMING PROTOTYPE ONLY (never live): current_user_permissions() answers from a transaction-local cache.
-- No invalidation on a mid-transaction grant change — that is exactly the open design question; this only measures the ceiling.
CREATE OR REPLACE FUNCTION public.current_user_permissions()
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v text := current_setting('app.perm_cache', true); k text := coalesce(auth.uid()::text, '-'); a text[];
BEGIN
    IF v IS NOT NULL AND v <> '' AND split_part(v, '|', 1) = k THEN
        RETURN substr(v, length(k) + 2)::text[];
    END IF;
    SELECT COALESCE(array_agg(DISTINCT rp.permission_code), ARRAY[]::text[]) INTO a
      FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN role_permissions rp ON rp.role_id = r.id
     WHERE ur.user_id = auth.uid() AND ur.revoked_at IS NULL AND r.is_active AND r.deleted_at IS NULL;
    PERFORM set_config('app.perm_cache', k || '|' || a::text, true);
    RETURN a;
END;
$function$;
