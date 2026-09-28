-- db/functions/record_account_event.sql
-- HISTORY-1(Tim 的 Q22 · Q23 · Q2 · Q3):登录账号的生命周期写进 change_log(table_name = 'auth.users')。
--
-- 【为什么由应用调、而不是触发器】auth 架构不是我们的(平台的),在它上面挂触发器不是本仓库能做的事;
--   auth.audit_log_entries 实测 0 行。所以 /settings/accounts 的服务端动作在调 auth 之前 / 之后,
--   用【调用者自己的会话】调本函数 —— 于是 actor 是那个按按钮的人,而不是服务角色。
-- 【事件】
--   ACCOUNT_CREATE          建好之后立刻记(关联与授角色之前 —— 那两步失败时要回滚的正是它)
--   ACCOUNT_DELETE          只剩一种:建到一半失败的回滚(reason = create_rolled_back)。
--                           判据:那个账号必须【已经不在】auth.users 里 —— 先删,后记。
--   ACCOUNT_DISABLE         先记后封(见下);这里做全部检查:
--                             不许停用自己(CANNOT_DISABLE_SELF)· 已停用(ACCOUNT_ALREADY_DISABLED)·
--                             最后一个真的管理员(LAST_ADMIN_PROTECTED,判据与 guard_last_admin 同一份:
--                             real_role_grants 的四条 × 在册启用的 is_system 角色,排除这个账号)
--   ACCOUNT_ENABLE          未停用(ACCOUNT_NOT_DISABLED)
--   ACCOUNT_*_FAILED        auth 那一步失败了:照实记一行,屏幕报错。不做状态检查。
-- 【先记后封,不是先封后记】两步不在一笔事务里。先封后记,记失败时就有一个【没有记录】的停用 ——
--   正是这一刀要消灭的东西;先记后封,封失败时有一行 *_FAILED 把前一行说清楚。
CREATE OR REPLACE FUNCTION public.record_account_event(p_user_id uuid, p_event text, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_uid   uuid := auth.uid();
    v_email text;
    v_ban   timestamptz;
    v_found boolean;
    v_seq   bigint;
BEGIN
    PERFORM require_permission('action.manage_permissions');

    IF p_event NOT IN ('ACCOUNT_CREATE', 'ACCOUNT_DELETE', 'ACCOUNT_DISABLE', 'ACCOUNT_DISABLE_FAILED',
                       'ACCOUNT_ENABLE', 'ACCOUNT_ENABLE_FAILED') THEN
        RAISE EXCEPTION 'ACCOUNT_EVENT_UNKNOWN|%', p_event;
    END IF;
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND';
    END IF;

    SELECT u.email::text, u.banned_until INTO v_email, v_ban FROM auth.users u WHERE u.id = p_user_id;
    v_found := FOUND;

    IF p_event = 'ACCOUNT_DELETE' THEN
        IF v_found THEN
            RAISE EXCEPTION 'ACCOUNT_STILL_EXISTS';
        END IF;
    ELSIF NOT v_found THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND';
    END IF;

    IF p_event = 'ACCOUNT_DISABLE' THEN
        IF p_user_id = v_uid THEN
            RAISE EXCEPTION 'CANNOT_DISABLE_SELF';
        END IF;
        IF v_ban IS NOT NULL AND v_ban > now() THEN
            RAISE EXCEPTION 'ACCOUNT_ALREADY_DISABLED';
        END IF;
        IF NOT EXISTS (
            SELECT 1
              FROM roles r
             CROSS JOIN LATERAL real_role_grants(r.code) g
             WHERE r.is_system AND r.is_active AND r.deleted_at IS NULL
               AND g.user_id <> p_user_id
        ) THEN
            RAISE EXCEPTION 'LAST_ADMIN_PROTECTED';
        END IF;
    ELSIF p_event = 'ACCOUNT_ENABLE' THEN
        IF v_ban IS NULL OR v_ban <= now() THEN
            RAISE EXCEPTION 'ACCOUNT_NOT_DISABLED';
        END IF;
    END IF;

    INSERT INTO change_log (table_name, row_key, op, actor_account, actor_employee, actor_kind, db_role, new)
    VALUES ('auth.users', jsonb_build_object('id', p_user_id), p_event, v_uid, account_person(v_uid),
            CASE WHEN v_uid IS NULL THEN 'no_session' ELSE 'user' END,
            COALESCE(NULLIF(current_setting('role', true), 'none'), session_user::text),
            jsonb_build_object('email', COALESCE(v_email, p_detail ->> 'email')) || COALESCE(p_detail, '{}'::jsonb) - 'email')
    RETURNING seq INTO v_seq;
    RETURN v_seq;
END;
$function$;
