-- ════════════════════════════════════════════════════════════════════════════
-- C-1 / Step 0b(2026-09-04):最后一个管理员守卫【只数真的数得上的授权】
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【缺陷】db/tables/user_roles.sql 的 guard_last_admin 判"除本行之外还有没有别的
--   管理员授权"时,只 JOIN 了 user_roles × roles —— **它从不看 auth.users**。
--   于是一条【幽灵授权】(user_id 在 auth.users 里根本不存在)可以顶替最后一个
--   真管理员:撤销真人的那一刻守卫说"还有一个",而那一个谁也解析不出来。
--   系统从此没有任何人能改权限,包括主人 —— 正是这个守卫存在的理由。
--   记在 docs/known-issues.md 的 GHOST-GRANTS 条:幽灵授权在本库出现过三次
--   (66 → 21 → 8 条),所以这不是一个假想的形状。
--
-- 【为什么修法是"复用 real_role_holders 的判据",而不是加一个 auth.users 的 JOIN】
--   本仓库已经有一份【唯一的】「谁算一个真的持有人」定义 ——
--   db/functions/real_role_holders.sql(CHAIN-BUILD-1)。它的四条是:
--     ① 授权未撤销  ② 账号已确认  ③ 未被封禁  ④ 未被删除
--   在这里另写一份"有没有 auth.users 行"的判据,就是造【第二份定义】,
--   而两份判据必然漂开 —— 那正是 real_role_holders 当初被抽出来消灭的东西。
--   ★ 而且弱判据today就已经不够:线上 chef1949@126.com 是【未确认】账号,
--     只查"有没有 auth.users 行"的话,它照样能顶替最后一个管理员。
--
-- 【障碍,以及为什么要新加一支函数】real_role_holders 返回的是 user_id 的集合,
--   而守卫必须排除【正在被撤销的那一行】(ur.id <> OLD.id)—— 一个 user_id 集合
--   表达不了行级排除。按 user_id 排除是【不等价】的:一个人若同时持有两个
--   is_system 角色就会误判,而 guard_system_role 只挡"摘掉 is_system",
--   【不挡】把 is_system 加到另一个角色上,所以第二个系统角色是造得出来的。
--   所以:新加 real_role_grants(返回 grant_id + user_id),
--   并把 real_role_holders 改写成它的【投影】—— 一份判据,两种形状,零漂移。
--
-- 【为什么 guard_last_admin 必须改成 SECURITY DEFINER】
--   real_role_grants 读 auth.users,所以它与 real_role_holders 一样,
--   EXECUTE 要从 authenticated 收回(否则任何登录用户都能把整个账号目录的
--   登录状态问出来)。而 guard_last_admin 此前是【调用者权限】的,
--   以 authenticated 身份跑时就【调不到】那支函数,守卫会在每一次撤销时报权限错。
--   改成 DEFINER 之后它以属主身份跑,调得到,而收回照旧成立。
--   ★ 这【不会】触发 gate 的 B2:B2_SQL 里写着
--     `AND pg_get_function_result(p.oid) <> 'trigger'` —— 触发器函数调不动,
--     闸门是触发它的那次基表写入(perm2a 的设计)。
--   连同 SET search_path —— 一个没有固定 search_path 的 DEFINER 函数本身是个洞。
--
-- 【今天不会触发】线上幽灵授权 0 条(实测 2026-09-04),所以本迁移【不改变任何
--   现有数据的行为】。它改变的是【下一次幽灵出现时】会发生什么。
--   证明写在 db/fixtures/ 的回滚 fixture 里:造一个幽灵,断言新判据拒绝、
--   旧判据放行,同一个事务里回滚。
--
-- 【产地仍然开着】GHOST-GRANTS 的成因(smoke-routes.mjs:1313 每跑一次就把真的
--   admin 角色授给一次性账号)本刀【没有】动。修的是"数错",不是"别再长出来"。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ① 判据的唯一定义,行级形状。四条与 real_role_holders 逐字相同 ——
--    因为下面 real_role_holders 就是从这里投影出来的。
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
$function$;

COMMENT ON FUNCTION public.real_role_grants(text) IS
'C-1:「谁算一个真的持有人」的行级形状 —— 返回 grant_id + user_id。real_role_holders 是它的投影,所以四条判据(未撤销 / 已确认 / 未封禁 / 未删除)全库只有这一份。存在的理由是 guard_last_admin 必须排除【正在被撤销的那一行】,而一个 user_id 集合表达不了行级排除;按 user_id 排除在一个人持有两个 is_system 角色时不等价,而第二个系统角色是造得出来的(guard_system_role 只挡摘掉 is_system,不挡加上)。EXECUTE 已从 authenticated 收回 —— 它读 auth.users。';

-- ② real_role_holders 从此是上面那支的投影。四条判据【不再在这里出现第二遍】。
--    签名与返回类型一字未动,三个既有调用方(guard_approvals_switch /
--    approvals_readiness / require_approver_for)完全不受影响。
CREATE OR REPLACE FUNCTION public.real_role_holders(p_role_code text)
 RETURNS TABLE(user_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT g.user_id FROM real_role_grants(p_role_code) g;
$function$;

COMMENT ON FUNCTION public.real_role_holders(text) IS
'CHAIN-BUILD-1:★「谁算一个真的持有人」的【唯一】定义★ —— 开关那道闸、就绪面板、以及授权检查,三处读的都是它。★ C-1(2026-09-04)把四条判据搬进 real_role_grants(行级形状,带 grant_id),本函数从此是它的【投影】—— 因为 guard_last_admin 需要排除【正在被撤销的那一行】,而一个 user_id 集合表达不了行级排除。判据一字未改:① 授权未撤销(**这一条当年是缺陷修复**:此前三处都没滤 revoked_at);②③④ 是 R3(账号已确认 / 未封禁 / 未删除),把"有一行账号记录"换成"真的登录得了"。confirmed_at 是生成列 LEAST(email_confirmed_at, phone_confirmed_at),故同时覆盖邮箱与手机。';

-- ③ 守卫改数【真的数得上的】授权。
--    与旧版的差别只有一处:数的来源从 user_roles×roles 换成 real_role_grants。
--    r.is_system / r.is_active / r.deleted_at 这三条【原样保留】——
--    real_role_grants 自己只管 r.is_active,不管 is_system 与软删,
--    那是守卫自己的判据,不该塞进那支通用函数里。
CREATE OR REPLACE FUNCTION public.guard_last_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
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
$fn$;

-- ④ 与 real_role_holders 同一条理由:它读 auth.users,给了 authenticated
--    就等于把整个账号目录的登录状态问出来。唯一的调用方 guard_last_admin
--    是【属主身份跑的触发器】,收回之后照常工作。
REVOKE EXECUTE ON FUNCTION public.real_role_grants(text) FROM authenticated;

COMMIT;
