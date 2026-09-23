-- db/functions/approval_level_eligible.sql
-- APR-ROUTE-1(Tim 的 R1 · Q1):【谁有资格批这一级】—— 高一级的人可以批低一级的单。
--
-- 【裁定,原样】持有更高审批级别的人,可以决定被分到更低一级的单据。
-- 只适用于【分档的金额链】。它存在的理由是:一级持有人【自己的】单据要有人批 ——
-- 线上 chooer 自己 1000 SGD 以下的报销单,此前【没有任何人】批得了
-- (一级只有他一个人,而他是主角;EMP-SELF-0 §2.2 的 F2)。
--
-- 【为什么它住在这里,而不是住在每一条链上】(Q1)
-- 分档的链有两个读"这一级谁有资格"的地方:
--   · require_approver_for(level)       —— 运行时,真的拦人的那一道;
--   · approval_gate_intersections(l1,l2)—— 经 approval_deciders,开关的闸与面板读它。
-- 两处都读本函数。★ 于是 APR-4 到 APR-6 接进来的链【什么都不用做】就继承 R1:
-- 调 require_approver_for,并在 approval_chain_gates() 里加一行 —— 这两件事
-- 它们本来就得做(fixture 203 的 E 臂钉着"名册 = 目录")。
--
-- 【"更高"就是 2 高于 1】approval_log.level 的 CHECK 只允许 1 与 2,
-- 所以"level ≥ 所需"在今天就是"一级另加二级的持有人"。
--
-- 【两个角色码当参数传,不自己读表】与 approval_gate_intersections 同一个理由:
-- guard_approvals_switch 是 BEFORE UPDATE,读表读到的是 OLD。
--
-- 【"真持有人"只有一份定义】real_role_holders(四条判据)。
--
-- 【为什么 SECURITY DEFINER 并被收权】它经 real_role_holders 读 auth.users 的
-- 登录状态;给了 authenticated 就等于把审批人名单问出来。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1a-higher-decides-lower-and-the-flagged-self.sql.

CREATE OR REPLACE FUNCTION public.approval_level_eligible(p_level smallint, p_level1_role text, p_level2_role text)
 RETURNS TABLE(user_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 这一级自己的角色
    SELECT h.user_id
      FROM real_role_holders(CASE p_level WHEN 1 THEN p_level1_role
                                          WHEN 2 THEN p_level2_role END) h
    UNION
    -- ★ R1:一级另加二级的持有人。二级之上没有更高的一级。
    SELECT h.user_id
      FROM real_role_holders(p_level2_role) h
     WHERE p_level = 1 AND p_level2_role IS NOT NULL
$function$;

COMMENT ON FUNCTION public.approval_level_eligible(smallint, text, text) IS
'APR-ROUTE-1(R1):谁有资格批这一级 —— 这一级角色的真持有人,一级另加二级的真持有人(高一级可以批低一级)。require_approver_for 与 approval_deciders(→ approval_gate_intersections)都读它,于是后来接进来的分档链调 require_approver_for、在 approval_chain_gates() 里加一行,就继承 R1。两个角色码当参数传:guard_approvals_switch 是 BEFORE UPDATE,读表读到的是 OLD。EXECUTE 已从 authenticated 收回。';
