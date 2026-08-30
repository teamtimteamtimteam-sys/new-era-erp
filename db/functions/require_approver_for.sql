CREATE OR REPLACE FUNCTION public.require_approver_for(p_level smallint)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_role text;
BEGIN
    IF p_level = 1 THEN
        SELECT approval_level1_role_code INTO v_role FROM finance_settings LIMIT 1;
        IF v_role IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_LEVEL1_ROLE_NOT_SET';
        END IF;
    ELSIF p_level = 2 THEN
        SELECT approval_level2_role_code INTO v_role FROM finance_settings LIMIT 1;
        IF v_role IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_LEVEL2_ROLE_NOT_SET';
        END IF;
    ELSE
        RAISE EXCEPTION 'APPROVAL_LEVEL_INVALID|%', p_level;
    END IF;

    -- ★ 与"有几个持有人"读同一份定义 —— 于是【一份撤销掉的授权批不了单】,
    --   而这一条此前是漏的(见本文件抬头的缺陷段)。
    IF NOT EXISTS (SELECT 1 FROM real_role_holders(v_role) h WHERE h.user_id = auth.uid()) THEN
        RAISE EXCEPTION 'APPROVAL_NOT_AUTHORISED|%|%', p_level, v_role;
    END IF;
END;
$function$;
