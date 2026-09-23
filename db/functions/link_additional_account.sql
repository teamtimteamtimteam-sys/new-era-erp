-- db/functions/link_additional_account.sql
-- APR-ROUTE-1 Batch B(Tim 的 R3 · Q6/Q9/Q1):把一个账号链成某人的【额外账号】。
--
-- 【闸】action.manage_permissions —— 与 /settings/accounts 同一个码(Q9)。
--
-- 【按名拒绝,逐条】
--   ADDITIONAL_NEEDS_PRIMARY|<工号> —— 那个人还没有主账号:该做的是"关联员工档案",
--        不是加一个额外账号。一个人只有额外账号、没有主账号,是一个不该出现的形状。
--   ACCOUNT_IS_PRIMARY|<工号>       —— 这个账号已经是某人的主账号(守卫也会拦,这里先说人话)。
--   ACCOUNT_ALREADY_ADDITIONAL|<工号> —— 它已经是某人的额外账号。
--   ★ ACCOUNT_HAS_DECISIONS|<n>     —— 它已经以决定人身份在 approval_log 里有 n 行(Tim 的 Q1)。
--        approval_log 只增不改,而 self_decided 是在做决定那一刻按【当时】它是谁算的。
--        把一个做过决定的账号链到某人身上,它过去关于这个人的决定就会变成
--        【从没被标记过的自批】,而且改不回来。其余的历史(created_by 之类)
--        只是换一个显示名,可以跟着重新解析 —— 所以只拦这一种。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1b-one-person-several-accounts-and-gm-reads.sql.

CREATE OR REPLACE FUNCTION public.link_additional_account(p_user_id uuid, p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp   employees%ROWTYPE;
    v_code  text;
    v_n     integer;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'USER_REQUIRED';
    END IF;
    IF p_employee_id IS NULL THEN
        RAISE EXCEPTION 'EMPLOYEE_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND';
    END IF;
    IF v_emp.user_id IS NULL THEN
        RAISE EXCEPTION 'ADDITIONAL_NEEDS_PRIMARY|%', v_emp.code;
    END IF;

    SELECT e.code INTO v_code FROM employees e WHERE e.user_id = p_user_id LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_IS_PRIMARY|%', v_code;
    END IF;

    SELECT e.code INTO v_code
      FROM employee_accounts ea JOIN employees e ON e.id = ea.employee_id
     WHERE ea.user_id = p_user_id;
    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_ALREADY_ADDITIONAL|%', v_code;
    END IF;

    -- ★ Tim 的 Q1:一个做过决定的账号不许被链到任何人身上
    SELECT count(*) INTO v_n FROM approval_log WHERE actor_user_id = p_user_id;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ACCOUNT_HAS_DECISIONS|%', v_n;
    END IF;

    INSERT INTO employee_accounts (user_id, employee_id, linked_by)
    VALUES (p_user_id, p_employee_id, auth.uid());

    INSERT INTO employee_account_history (action, user_id, employee_id, actor_user_id)
    VALUES ('linked', p_user_id, p_employee_id, auth.uid());

    RETURN jsonb_build_object('user_id', p_user_id, 'employee_id', p_employee_id,
                              'employee_code', v_emp.code, 'linked', true);
END;
$function$;
