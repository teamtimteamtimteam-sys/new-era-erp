-- db/functions/set_user_employee_link.sql
-- 账号 ↔ 员工档案的关联,一次调用里同生共死。要 action.manage_permissions。
--
-- 修的是 cut 3 的遗留:界面当时用两条语句做(先清旧的、再设新的),中间失败
-- 账号就谁也不关联了。收进函数后两次写入在同一个事务里,要么都成要么都不成。
-- 传 NULL 表示解绑。目标员工已绑在别的账号上时抛 EMPLOYEE_ALREADY_LINKED|<工号>。
--
-- NOTE: introduced by db/migrations/2026-08-02-perm4-self-service.sql.

CREATE OR REPLACE FUNCTION public.set_user_employee_link(p_user_id uuid, p_employee_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_prev  uuid;
    v_owner uuid;
    v_code  text;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'USER_REQUIRED';
    END IF;

    -- 目标员工若已经绑在【别的】账号上,拒绝 —— employees.user_id 上的
    -- partial unique index 也会拦,但那样抛出来的是索引名,不是人话。
    IF p_employee_id IS NOT NULL THEN
        SELECT user_id, code INTO v_owner, v_code
        FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND';
        END IF;
        IF v_owner IS NOT NULL AND v_owner <> p_user_id THEN
            RAISE EXCEPTION 'EMPLOYEE_ALREADY_LINKED|%', v_code;
        END IF;
    END IF;

    SELECT id INTO v_prev FROM employees WHERE user_id = p_user_id;

    -- 解绑旧的 + 绑上新的。两条 UPDATE 在同一个函数体里,
    -- 任何一条失败整个调用回滚 —— 不会再出现"清掉了但没设上"的中间态。
    UPDATE employees SET user_id = NULL
    WHERE user_id = p_user_id
      AND (p_employee_id IS NULL OR id <> p_employee_id);

    IF p_employee_id IS NOT NULL THEN
        UPDATE employees SET user_id = p_user_id WHERE id = p_employee_id;
    END IF;

    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'previous_employee_id', v_prev,
        'employee_id', p_employee_id
    );
END;
$function$;
