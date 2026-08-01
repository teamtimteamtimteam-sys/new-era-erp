-- db/functions/set_user_roles.sql
-- 授予/撤销某个账号的角色。要 action.manage_permissions。
-- 【撤销是记录不是删除】—— revoked_at/by/reason 留着,授权史查得到。
-- cut 1 的最后一个管理员守卫照常触发,本函数不做任何绕过。
--
-- NOTE: introduced by db/migrations/2026-08-02-perm3-banking-and-directory.sql.

CREATE OR REPLACE FUNCTION public.set_user_roles(p_user_id uuid, p_role_ids uuid[], p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_target  uuid[] := COALESCE(p_role_ids, ARRAY[]::uuid[]);
    v_granted uuid[];
    v_revoked uuid[];
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'USER_REQUIRED';
    END IF;

    -- 目标角色必须都存在且在册
    IF EXISTS (
        SELECT 1 FROM unnest(v_target) t(role_id)
        WHERE NOT EXISTS (SELECT 1 FROM roles r WHERE r.id = t.role_id AND r.deleted_at IS NULL)
    ) THEN
        RAISE EXCEPTION 'ROLE_NOT_FOUND';
    END IF;

    -- 新增:目标里有、当前未持有的
    WITH added AS (
        INSERT INTO user_roles (user_id, role_id, granted_by)
        SELECT p_user_id, t.role_id, auth.uid()
        FROM unnest(v_target) t(role_id)
        WHERE NOT EXISTS (
            SELECT 1 FROM user_roles ur
            WHERE ur.user_id = p_user_id AND ur.role_id = t.role_id AND ur.revoked_at IS NULL
        )
        RETURNING role_id
    )
    SELECT array_agg(role_id) INTO v_granted FROM added;

    -- 撤销:当前持有、目标里没有的。【UPDATE 而非 DELETE】。
    -- 最后一个管理员守卫就挂在这条 UPDATE 上,该拦的时候会在这里抛出来。
    WITH revoked AS (
        UPDATE user_roles ur
        SET revoked_at = now(), revoked_by = auth.uid(), revoke_reason = p_reason
        WHERE ur.user_id = p_user_id
          AND ur.revoked_at IS NULL
          AND NOT (ur.role_id = ANY (v_target))
        RETURNING ur.role_id
    )
    SELECT array_agg(role_id) INTO v_revoked FROM revoked;

    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'granted', COALESCE(to_jsonb(v_granted), '[]'::jsonb),
        'revoked', COALESCE(to_jsonb(v_revoked), '[]'::jsonb),
        'roles_now', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('role_id', r.id, 'code', r.code)
                             ORDER BY r.sort_order, r.code)
            FROM user_roles ur JOIN roles r ON r.id = ur.role_id
            WHERE ur.user_id = p_user_id AND ur.revoked_at IS NULL AND r.deleted_at IS NULL
        ), '[]'::jsonb)
    );
END;
$function$;
