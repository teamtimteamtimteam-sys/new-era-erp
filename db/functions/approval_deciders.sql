-- db/functions/approval_deciders.sql
-- APR-ROUTE-1(Tim 的 R4 · Q10):【"除了单据的主角,还有没有人批得动"的唯一一份定义】
--
-- 【它补的洞】APR-2 的 approval_gate_intersections 问的是"这一级有没有人持有",
-- 而一个只有一个持有人的级别,对【那个持有人自己的单据】是死的:
-- 提单人那条腿拦他,而没有第二个人。线上 chooer 自己的小额报销与
-- admin 自己的大额采购单都是这个形状,而求交报的是 1、闸是绿的(EMP-SELF-0 F2)。
--
-- 【判据,一行一行】对一条链(subject_type + action_function)的一级,
-- 一个账号 u 算"批得动这一张"当且仅当:
--   ① u ∈ approval_level_eligible(level, l1, l2)          —— 这一级有资格(含 R1)
--   ② u 持有这条链自己的模块门(approval_chain_gates 的 gate_permissions,合取)
--   ③ self_leg(提单人, 主角, u) = 'none'                    —— 不是"自己"
--      或者 self_approval_exception(...) 成立                —— R2 的那个例外
-- 返回的是【人】,不是账号(R3):同一个人的两个账号只算一个。
--
-- 【三个读者,一份判据】(Q10)
--   · approval_gate_intersections  —— 不传提单人与主角:"这一级有没有任何人"
--                                     → 开关那道闸(APPROVALS_CHAIN_HAS_NO_APPROVER)与面板;
--   · approvals_readiness          —— 逐个持有人代入:"他自己的单谁来批"(忠告,不拦);
--   · guard_approvals_switch       —— 每一张在途单据的真实提单人与主角
--                                     → APPROVALS_POLICY_WOULD_STRAND。
--
-- 【"真持有权限"只有一份定义】与 approval_gate_intersections 原来的 real_perm
-- 逐字同源:从 real_role_grants 长出来,于是撤销的授权、登录不了的账号两侧同时不算。
--
-- 【via_self_exception】这一行之所以算数,是因为 R2 的例外 —— 面板要分开
-- "有别人批"与"只能自批"两种状态,前者正常,后者要被看见。
--
-- 【为什么 SECURITY DEFINER 并被收权】它读 auth.users 的登录状态与整张权限矩阵。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1a-higher-decides-lower-and-the-flagged-self.sql.

CREATE OR REPLACE FUNCTION public.approval_deciders(p_subject_type text, p_action_function text, p_level smallint, p_raiser uuid, p_subject_employee uuid, p_level1_role text, p_level2_role text)
 RETURNS TABLE(user_id uuid, person_key text, via_self_exception boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH gate AS (
        SELECT cg.gate_permissions
          FROM approval_chain_gates() cg
         WHERE cg.subject_type = p_subject_type
           AND cg.action_function = p_action_function
           AND cg.level = p_level
    ),
    -- 「谁【真的】持有权限 P」—— 四条判据借自 real_role_grants,不另写一份。
    real_perm AS (
        SELECT DISTINCT rp.permission_code, rg.user_id
          FROM role_permissions rp
          JOIN roles r ON r.id = rp.role_id
          CROSS JOIN LATERAL real_role_grants(r.code) rg
    ),
    cand AS (
        SELECT e.user_id,
               self_leg(p_raiser, p_subject_employee, e.user_id) AS leg,
               self_approval_exception(p_subject_type, p_subject_employee, e.user_id, p_level2_role) AS exc
          FROM approval_level_eligible(p_level, p_level1_role, p_level2_role) e
         CROSS JOIN gate g
         -- 门是【合取】:少一个码就不算
         WHERE NOT EXISTS (
                 SELECT 1 FROM unnest(g.gate_permissions) AS need(code)
                  WHERE NOT EXISTS (
                        SELECT 1 FROM real_perm pp
                         WHERE pp.permission_code = need.code
                           AND pp.user_id = e.user_id))
    )
    SELECT c.user_id,
           COALESCE(account_person(c.user_id)::text, 'account:' || c.user_id::text),
           (c.leg <> 'none')
      FROM cand c
     WHERE c.leg = 'none' OR c.exc
$function$;

COMMENT ON FUNCTION public.approval_deciders(text, text, smallint, uuid, uuid, text, text) IS
'APR-ROUTE-1(R4):一条链的一级,对一份提单人为 p_raiser、主角为 p_subject_employee 的单据,谁批得动 —— 有资格(approval_level_eligible,含 R1)∩ 持这条链的模块门 ∩(不是"自己" 或 R2 例外成立)。person_key 按人认(R3):同一个人的两个账号只算一个。via_self_exception = 这一行只因 R2 才算数。三个读者:approval_gate_intersections(不传提单人与主角)· approvals_readiness(逐个持有人代入,忠告)· guard_approvals_switch 的 WOULD_STRAND(在途单据的真实双方)。EXECUTE 已从 authenticated 收回。';
