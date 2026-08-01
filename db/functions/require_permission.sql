-- db/functions/require_permission.sql
-- The single permission gate used by every SECURITY DEFINER RPC entry point.
-- DEFINER makes those functions callable by anyone authenticated, so each one calls
-- this at the top with the permission of the ACTION it performs (not of the tables it
-- happens to touch). One error code, PERMISSION_DENIED|<code>, for the app to localize.
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2a-module-enforcement.sql.

CREATE OR REPLACE FUNCTION public.require_permission(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT has_permission(p_code) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|%', p_code;
    END IF;
END;
$function$;
