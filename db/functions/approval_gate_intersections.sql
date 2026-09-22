-- db/functions/approval_gate_intersections.sql
-- APR-2:【每一条接上引擎的链,真的有几个人批得动?】
--
-- 它把 approval_chain_gates()(那条链的模块门)与 real_role_holders()(那一级的
-- 角色持有人)求交,逐条给出 approvers 计数。**0 就是一条批不动的链。**
-- 缘由、实测与那次线上死锁写在 db/functions/approval_chain_gates.sql 的抬头。
--
-- 【两个调用方,两种用法 —— 而参数正是为了第二个而存在】
--   · approvals_readiness()   —— 不传参,读 finance_settings 上【已经落库】的角色;
--   · guard_approvals_switch() —— ★ 必须传 NEW 的两个角色码。
--     ★★ 这一格是设计的,不是顺手加的:它是一支 **BEFORE UPDATE** 触发器,
--        而 set_approvals_policy 把【四列一起写】。此刻从 finance_settings 读到的
--        是 **OLD** 那一行 —— 也就是【正在被换掉的那个角色】。
--        不传参,这道闸判的就是上一版策略,而它会全绿。
--        一道判错了主语的闸,与没有闸是同一件事。
--
-- 【判据只有一份定义,两处都没有第二份】
--   · 「谁算一个真的持有人」→ real_role_holders / real_role_grants(四条判据);
--   · 「谁持有权限 P」→ real_perm 这个 CTE,而它【也是】从 real_role_grants 长出来的,
--     所以一个撤销掉的授权、一个登录不了的账号,在两侧同时不算数。
--     ★ 写成 `JOIN user_roles` 会造出第二份"真人"的定义,而那正是
--       CHAIN-BUILD-1 花了一刀去消灭的东西(当年 admin 虚报 6 个持有人,真值 1)。
--
-- 【为什么 SECURITY DEFINER,以及它为什么必须被收权】它读 auth.users 的登录状态
-- (经 real_role_grants)与整张权限矩阵。给了 authenticated 就等于把账号目录问出来
-- —— 与 real_role_holders / role_can_see_amounts 逐字同一条理由。
-- 收权写在 db/views/zzz_function_grants.sql(★ 写在迁移里不算数 —— C-1 实测过:
-- apply_migration.sh 会在 COMMIT 之前重放那个文件,把只写在迁移里的授权冲掉)。
-- 两个调用方都是 SECURITY DEFINER、以属主身份执行,所以收回之后照常工作。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql.

CREATE OR REPLACE FUNCTION public.approval_gate_intersections(p_level1_role text DEFAULT NULL::text, p_level2_role text DEFAULT NULL::text)
 RETURNS TABLE(subject_type text, action_function text, level smallint, role_code text, gate_permissions text[], approvers integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH s AS (
        SELECT COALESCE(p_level1_role, fs.approval_level1_role_code) AS l1,
               COALESCE(p_level2_role, fs.approval_level2_role_code) AS l2
          FROM finance_settings fs
         LIMIT 1
    ),
    -- 「谁【真的】持有权限 P」—— 四条判据借自 real_role_grants,不另写一份。
    real_perm AS (
        SELECT DISTINCT rp.permission_code, rg.user_id
          FROM role_permissions rp
          JOIN roles r ON r.id = rp.role_id
          CROSS JOIN LATERAL real_role_grants(r.code) rg
    ),
    g AS (
        SELECT cg.subject_type, cg.action_function, cg.level, cg.gate_permissions,
               CASE cg.level WHEN 1 THEN s.l1 ELSE s.l2 END AS role_code
          FROM approval_chain_gates() cg
         CROSS JOIN s
    )
    SELECT g.subject_type, g.action_function, g.level, g.role_code, g.gate_permissions,
           (SELECT count(*)::integer
              FROM real_role_holders(g.role_code) h
             -- 门是【合取】:少一个码就不算 —— 所以是"不存在一个他没有的码"
             WHERE NOT EXISTS (
                     SELECT 1 FROM unnest(g.gate_permissions) AS need(code)
                      WHERE NOT EXISTS (
                            SELECT 1 FROM real_perm pp
                             WHERE pp.permission_code = need.code
                               AND pp.user_id = h.user_id)))
      FROM g
     ORDER BY g.subject_type, g.action_function, g.level
$function$;

COMMENT ON FUNCTION public.approval_gate_intersections(text, text) IS
'APR-2:逐条给出「这条链的模块门 ∩ 这一级的角色持有人」有几个人 —— 0 就是一条谁都批不动的链。★ 两个参数存在的理由:guard_approvals_switch 是 BEFORE UPDATE,从 finance_settings 读到的是 OLD 那一行,而策略四列是一起写的;不传 NEW 的角色码,那道闸判的就是上一版策略并且全绿。不传参时读已落库的值(approvals_readiness 的用法)。「真的持有人」与「真的持有权限」两侧都从 real_role_grants 长出来,所以全库仍然只有一份"真人"的判据。EXECUTE 已从 authenticated 收回 —— 它读 auth.users 与整张权限矩阵。';
