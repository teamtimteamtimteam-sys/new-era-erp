CREATE OR REPLACE FUNCTION public.require_approver_for(p_level smallint)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_role text;
    v_user uuid;
BEGIN
    IF p_level = 1 THEN
        SELECT approval_level1_role_code INTO v_role FROM finance_settings LIMIT 1;
        IF v_role IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_LEVEL1_ROLE_NOT_SET';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
            WHERE ur.user_id = auth.uid() AND r.code = v_role AND r.is_active
        ) THEN
            RAISE EXCEPTION 'APPROVAL_NOT_AUTHORISED|1|%', v_role;
        END IF;
    ELSIF p_level = 2 THEN
        SELECT approval_level2_user_id INTO v_user FROM finance_settings LIMIT 1;
        IF v_user IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_LEVEL2_USER_NOT_SET';
        END IF;
        IF auth.uid() IS DISTINCT FROM v_user THEN
            RAISE EXCEPTION 'APPROVAL_NOT_AUTHORISED|2|%', v_user;
        END IF;
    ELSE
        RAISE EXCEPTION 'APPROVAL_LEVEL_INVALID|%', p_level;
    END IF;
END;
$function$;