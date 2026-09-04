-- db/functions/real_role_grants.sql
-- C-1(2026-09-04):「谁算一个真的持有人」的【行级】形状。
--
-- 【它与 real_role_holders 的关系:一份判据,两种形状】
--   real_role_holders 从此是【本函数的投影】(SELECT g.user_id FROM real_role_grants)。
--   四条判据只在这里写一次 —— 那正是 CHAIN-BUILD-1 抽出 real_role_holders 时
--   要消灭的东西:两份判据必然漂开。
--
-- 【为什么需要行级形状】guard_last_admin 必须排除【正在被撤销的那一行】
--   (ur.id <> OLD.id),而一个 user_id 的集合表达不了行级排除。
--   ★ 按 user_id 排除是【不等价】的:一个人同时持有两个 is_system 角色时会误判,
--     而 guard_system_role 只挡"把 is_system 摘掉",【不挡】把它加到另一个角色上 ——
--     所以第二个系统角色是造得出来的。
--
-- 【四条判据,与 real_role_holders 当年逐字相同】
--   ① ur.revoked_at IS NULL —— 撤销掉的授权不算数。
--   ② u.confirmed_at IS NOT NULL —— 生成列 LEAST(email_confirmed_at, phone_confirmed_at),
--      同时覆盖邮箱与手机。★ 这一条今天就在起作用:线上 chef1949@126.com 是未确认账号。
--   ③ 未被封禁。 ④ 未被删除。
--
-- 【它【不】判角色软删】沿用既有判据里的 r.is_active,不多不少 ——
--   is_system 与软删是【守卫自己的】判据,写在 guard_last_admin 里,不塞进这支通用函数。
--
-- 【为什么 authenticated 调不到它】它读 auth.users 与 user_roles,给了任何登录用户
--   就等于把整个账号目录的登录状态问出来。唯一的调用方 guard_last_admin 是
--   【属主身份跑的触发器】(C-1 把它改成 SECURITY DEFINER 正是为了这个),
--   收回之后照常工作 —— 见 db/views/zzz_function_grants.sql。
--
-- NOTE: introduced by db/migrations/2026-09-04-c1-guard-last-admin-counts-real-holders.sql.
CREATE OR REPLACE FUNCTION public.real_role_grants(p_role_code text)
 RETURNS TABLE(grant_id uuid, user_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT ur.id, ur.user_id
      FROM user_roles ur
      JOIN roles r      ON r.id = ur.role_id
      JOIN auth.users u ON u.id = ur.user_id
     WHERE r.code = p_role_code
       AND r.is_active
       AND ur.revoked_at IS NULL                                    -- ①
       AND u.confirmed_at IS NOT NULL                               -- ②
       AND (u.banned_until IS NULL OR u.banned_until < now())       -- ③
       AND u.deleted_at IS NULL;                                    -- ④
$function$

COMMENT ON FUNCTION public.real_role_grants(text) IS
'C-1:「谁算一个真的持有人」的行级形状 —— 返回 grant_id + user_id。real_role_holders 是它的投影,所以四条判据(未撤销 / 已确认 / 未封禁 / 未删除)全库只有这一份。存在的理由是 guard_last_admin 必须排除【正在被撤销的那一行】,而一个 user_id 集合表达不了行级排除;按 user_id 排除在一个人持有两个 is_system 角色时不等价,而第二个系统角色是造得出来的(guard_system_role 只挡摘掉 is_system,不挡加上)。EXECUTE 已从 authenticated 收回 —— 它读 auth.users。';