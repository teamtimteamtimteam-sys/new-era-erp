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
-- 【可执行的那一份在 docs/fresh-install-checklist.md 第 4 步】,连同它的前提
-- (auth 用户要先在 Supabase 控制台里建出来,以及去哪里找它的 UUID)。
-- 【这里不再抄一份 SQL】—— 两份会各自漂移,而漂移的那一天正是有人照着建库的那一天。
-- 【也不为它建脚本】这件事一个库只跑一次;为一次性的事留一个常驻产物,
-- 与当初删掉 grant_annual_leave 而不是留着"备用"是同一个判断。
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
--
-- ★★【C-1(2026-09-04):它现在只数【真的数得上的】授权】★★
-- 【此前的缺陷】这里只 JOIN 了 user_roles × roles ——【它从不看 auth.users】。
--   于是一条【幽灵授权】(user_id 在 auth.users 里根本不存在)可以顶替最后一个
--   真管理员:撤销真人的那一刻守卫说"还有一个",而那一个谁也解析不出来。
--   幽灵授权在本库出现过三次(66 → 21 → 8 条,见 docs/known-issues.md 的
--   GHOST-GRANTS),所以这不是一个假想的形状。
-- 【修法】判据不在这里重写,而是调 real_role_grants ——
--   本仓库【唯一】的「谁算一个真的持有人」定义(未撤销 / 已确认 / 未封禁 / 未删除)。
--   在这里另写一个"有没有 auth.users 行"的判据,就是造第二份定义,而两份必然漂开。
--   ★ 弱判据今天就已经不够:线上 chef1949@126.com 是【未确认】账号,
--     只问"有没有行"的话它照样顶得上最后一个管理员。
-- 【is_system / is_active / deleted_at 三条留在这里】它们是【守卫自己的】判据,
--   不是"谁算真持有人"的一部分,所以不塞进那支通用函数。
-- 【为什么它成了 SECURITY DEFINER】real_role_grants 读 auth.users,EXECUTE 已从
--   authenticated 收回;调用者权限的触发器以 authenticated 身份跑就【调不到】它,
--   守卫会在每一次撤销时抛权限错。DEFINER 让它以属主身份跑,两者同时成立。
--   ★ 这不触发 gate 的 B2 —— B2_SQL 里写着 pg_get_function_result <> 'trigger'。
-- 【证明】db/fixtures/191:造一个幽灵,断言旧判据放行、新判据拒绝、守卫真的抛,
--   并且第二个真管理员在场时撤销照常成功(一道只会拒的闸与拦不住的闸一样坏)。
CREATE OR REPLACE FUNCTION public.guard_last_admin()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 只在"撤销"或"删除"时检查;新授权与其它字段更新一概放行
    IF TG_OP = 'DELETE' OR (OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL) THEN
        -- 除本行之外,是否还剩至少一条【真的数得上的】、指向【在册启用的
        -- is_system 角色】的授权。「真的数得上」= real_role_grants 的四条。
        IF NOT EXISTS (
            SELECT 1
            FROM roles r
            CROSS JOIN LATERAL real_role_grants(r.code) g
            WHERE r.is_system
              AND r.is_active
              AND r.deleted_at IS NULL
              AND g.grant_id <> OLD.id
        ) THEN
            RAISE EXCEPTION 'LAST_ADMIN_PROTECTED';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

CREATE TRIGGER trg_user_roles_last_admin
    BEFORE UPDATE OR DELETE ON public.user_roles
    FOR EACH ROW EXECUTE FUNCTION public.guard_last_admin();

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "user_roles select by permission"
    ON public.user_roles
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

CREATE POLICY "user_roles insert by permission"
    ON public.user_roles
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.manage_permissions'::text));

CREATE POLICY "user_roles update by permission"
    ON public.user_roles
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.manage_permissions'::text)) WITH CHECK (has_permission('action.manage_permissions'::text));

CREATE POLICY "user_roles delete by permission"
    ON public.user_roles
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('action.manage_permissions'::text));
