-- db/tables/user_roles.sql
-- 人 × 角色。一个人可以持有多个角色,【有效权限是并集】
-- (见 db/functions/current_user_permissions.sql)。
--
-- 撤销是【记录】而不是删除:谁在什么时候因为什么收回了权限,这段历史要留着。
-- 部分唯一索引保证同一个人对同一角色同时只有一条未撤销的授权(撤销后可再授)。
-- user_id 指向 auth.users 但【不建到 auth 架构的外键】(与既有表一致,只存 uuid)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【首建时必须补一步:引导授权】
-- 本文件不含 user_roles 的种子 —— 授给谁取决于目标环境里有哪些 auth 用户,
-- 不是可以写死的东西。但【空表是陷阱】:强制执行一旦打开,没有任何在册管理员
-- 授权就意味着谁也改不了权限、谁也补不上管理员,包括系统的主人,只能直连数据库救。
-- 所以首建后必须立刻执行(迁移里做的就是这件事):
--     INSERT INTO user_roles (user_id, role_id)
--     SELECT u.id, (SELECT id FROM roles WHERE code='admin') FROM auth.users u;
-- 且零用户时应当直接报错,而不是"成功"地建出一个没有管理员的系统。
-- ════════════════════════════════════════════════════════════════════════════
--
-- NOTE: introduced by db/migrations/2026-08-01-perm1-permission-skeleton.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.user_roles (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid NOT NULL,
    role_id       uuid NOT NULL REFERENCES public.roles (id) ON DELETE RESTRICT,
    granted_at    timestamptz NOT NULL DEFAULT now(),
    granted_by    uuid,
    revoked_at    timestamptz,
    revoked_by    uuid,
    revoke_reason text
);

CREATE UNIQUE INDEX idx_user_roles_active
    ON public.user_roles (user_id, role_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_user_roles_user ON public.user_roles (user_id) WHERE revoked_at IS NULL;

-- 不许撤到零个管理员。【请不要因为"看起来多余"而删掉这个守卫】:
-- 它防的是一次点击造成的不可逆状态 —— 见上面的引导说明。
CREATE OR REPLACE FUNCTION public.guard_last_admin()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 只在"撤销"或"删除"时检查;新授权与其它字段更新一概放行
    IF TG_OP = 'DELETE' OR (OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL) THEN
        -- 除本行之外,是否还剩至少一条【未撤销】且指向【在册启用的 is_system 角色】的授权
        IF NOT EXISTS (
            SELECT 1
            FROM user_roles ur
            JOIN roles r ON r.id = ur.role_id
            WHERE ur.id <> OLD.id
              AND ur.revoked_at IS NULL
              AND r.is_system
              AND r.is_active
              AND r.deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'LAST_ADMIN_PROTECTED';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$fn$;

CREATE TRIGGER trg_user_roles_last_admin
    BEFORE UPDATE OR DELETE ON public.user_roles
    FOR EACH ROW EXECUTE FUNCTION public.guard_last_admin();

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on user_roles"
    ON public.user_roles AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
