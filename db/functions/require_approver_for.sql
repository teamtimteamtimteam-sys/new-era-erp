CREATE OR REPLACE FUNCTION public.require_approver_for(p_level smallint)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_role text;
    v_l1   text;
    v_l2   text;
BEGIN
    SELECT approval_level1_role_code, approval_level2_role_code
      INTO v_l1, v_l2 FROM finance_settings LIMIT 1;

    IF p_level = 1 THEN
        v_role := v_l1;
        IF v_role IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_LEVEL1_ROLE_NOT_SET';
        END IF;
    ELSIF p_level = 2 THEN
        v_role := v_l2;
        IF v_role IS NULL THEN
            RAISE EXCEPTION 'APPROVAL_LEVEL2_ROLE_NOT_SET';
        END IF;
    ELSE
        RAISE EXCEPTION 'APPROVAL_LEVEL_INVALID|%', p_level;
    END IF;

    -- ★ APR-ROUTE-1(R1):「这一级谁有资格」只有一份定义 —— approval_level_eligible。
    --   一级另加二级的持有人(高一级可以批低一级);二级只有二级。
    --   拒绝的文案不变:它说的仍然是【这一级】的角色,那是人该去找的那个。
    IF NOT EXISTS (SELECT 1 FROM approval_level_eligible(p_level, v_l1, v_l2) h
                    WHERE h.user_id = auth.uid()) THEN
        RAISE EXCEPTION 'APPROVAL_NOT_AUTHORISED|%|%', p_level, v_role;
    END IF;
END;
$function$;
