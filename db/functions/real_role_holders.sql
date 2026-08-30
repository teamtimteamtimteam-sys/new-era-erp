-- db/functions/real_role_holders.sql
-- CHAIN-BUILD-1:★「谁算一个真的持有人」的【唯一】定义★
--
-- 【它服务三个调用方,而那正是它存在的理由】
--   · guard_approvals_switch —— 开关时"这一级有几个人"
--   · approvals_readiness    —— 屏幕上"这一级有几个人"
--   · require_approver_for   —— 授权时"这个人算不算"
--   写成【计数】函数只能答前两个,第三个就得另写一份判据 —— 而两份判据
--   必然漂开,那正是本刀要消灭的东西。所以它返回【集合】。
--
-- 【四条判据,第 ① 条是缺陷修复,②③④ 是 R3】
--   ① ur.revoked_at IS NULL —— ★此前三处都没滤★。实测线上 15 条授权里 5 条已撤销,
--      admin 因此虚报 6 个持有人(真值 1)。也就是说:一个把授权【全部撤销】的角色
--      照样通过零持有人那道闸,而撤销授权的人以为自己已经把这条路关上了。
--   ② u.confirmed_at IS NOT NULL —— confirmed_at 是【生成列】
--      LEAST(email_confirmed_at, phone_confirmed_at),所以它同时覆盖邮箱与手机,
--      比只看 email_confirmed_at 更准。
--   ③ 未被封禁 —— **在今天的数据上它不是起作用的那一条**(五个被封账号的授权也已撤销),
--      而且 banned_until 在本仓库别处一次都没出现过(那些封禁是仓库之外做的)。
--      保留它,只因为 R3 的原话是"真的登录得了",而被封的账号登录不了。
--   ④ 未被删除。
--
-- 【它【不】判角色软删】沿用既有判据里的 r.is_active,不多不少。实测线上
--   软删角色 0 个,所以今天两者等价;真出现"软删了但仍 is_active"时这里会多算 ——
--   报告出来,不顺手改(那是另一条规矩)。
--
-- 【为什么 authenticated 调不到它】它读 auth.users 与 user_roles,给了任何登录用户
--   就等于把整个账号目录的登录状态与权限矩阵问出来。三个调用方都是 SECURITY DEFINER、
--   以属主身份执行,所以收回之后照常工作 —— 见 db/views/zzz_function_grants.sql。
CREATE OR REPLACE FUNCTION public.real_role_holders(p_role_code text)
 RETURNS TABLE(user_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT ur.user_id
      FROM user_roles ur
      JOIN roles r      ON r.id = ur.role_id
      JOIN auth.users u ON u.id = ur.user_id
     WHERE r.code = p_role_code
       AND r.is_active
       AND ur.revoked_at IS NULL                                    -- ① 缺陷修复
       AND u.confirmed_at IS NOT NULL                               -- ② R3
       AND (u.banned_until IS NULL OR u.banned_until < now())       -- ③ R3
       AND u.deleted_at IS NULL;                                    -- ④ R3
$function$;

COMMENT ON FUNCTION public.real_role_holders(text) IS
'CHAIN-BUILD-1:★「谁算一个真的持有人」的【唯一】定义★ —— 开关那道闸、就绪面板、以及授权检查,三处读的都是它。返回【集合】而不是计数,是因为同一份判据要回答两个问题(有几个 / 这个人算不算),写成计数就会逼出第二份判据。四条:① 授权未撤销(**这一条是缺陷修复**:此前三处都没滤 revoked_at,于是一个把授权全撤销掉的角色照样能通过零持有人那道闸;实测线上 15 条授权里 5 条是 revoked,admin 因此虚报 6 个持有人);②③④ 是 R3(账号已确认 / 未封禁 / 未删除),把"有一行账号记录"换成"真的登录得了"。confirmed_at 是生成列 LEAST(email_confirmed_at, phone_confirmed_at),故同时覆盖邮箱与手机。**banned_until 在今天的数据上不是起作用的那一条**(那五个被封账号的授权也已撤销),而且它在本仓库别处一次都没出现过 —— 保留它只因为 R3 的原话是"真的登录得了"。';
