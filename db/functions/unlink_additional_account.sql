-- db/functions/unlink_additional_account.sql
-- APR-ROUTE-1 Batch B(Tim 的 Q2):解除一个额外账号。
--
-- 【闸】action.manage_permissions。解除落一行 employee_account_history。
-- ★ 过去的 approval_log.self_decided【原样保留】—— 它记的是做决定那一刻的事实,
--   那一刻这个账号确实属于那个人;解除链接改变的是【以后】它算谁。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1b-one-person-several-accounts-and-gm-reads.sql.

CREATE OR REPLACE FUNCTION public.unlink_additional_account(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp uuid;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'USER_REQUIRED';
    END IF;

    DELETE FROM employee_accounts WHERE user_id = p_user_id
    RETURNING employee_id INTO v_emp;
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_ADDITIONAL';
    END IF;

    INSERT INTO employee_account_history (action, user_id, employee_id, actor_user_id)
    VALUES ('unlinked', p_user_id, v_emp, auth.uid());

    RETURN jsonb_build_object('user_id', p_user_id, 'employee_id', v_emp, 'linked', false);
END;
$function$;
