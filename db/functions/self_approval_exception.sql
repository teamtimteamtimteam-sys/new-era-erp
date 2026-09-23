-- db/functions/self_approval_exception.sql
-- APR-ROUTE-1(Tim 的 R2 · Q3):【"不许自己批自己"的唯一一个例外】—— 它在哪里成立。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【Tim 的裁定,原样】最高一级审批角色的持有人(今天是 cfo),可以决定
-- 【他自己的】报销单与医疗申报。每一次这样的决定都在 approval_log 里标成自批,
-- 并有一张报表列出全部自批。**这个例外永远不覆盖**薪资、绩效、调薪、请假,
-- 或任何别的单据类型。Tim 选它而不选"把自己的单送给 MD",是有意识地选了
-- 【可追溯】而不是【可防止】。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【三个条件,缺一不可】(Q3)
--   ① 单据类型是 expense_claim 或 medical_claim —— 写死在这里,★ 而且只写在这里;
--      approval_log 上的 CHECK(approval_log_self_decided_scope)是同一句话的
--      第二道保险:哪一天别的路径让一次自批漏过去,落留痕那一刻当场报错。
--   ② 这个账号属于【单据说的那个人】(经 account_person 按人认)。
--   ③ 这个账号【此刻】持有 finance_settings.approval_level2_role_code 那个角色
--      (真持有人判据,real_role_holders)。二级角色没设 → 没有例外。
--
-- 【它【不】放宽任何模块门】(Q5)本函数只回答"自批这一条拒不拒";
-- 能不能走到这一步,仍然由每一支决定函数自己的 require_permission 决定。
-- ☞ 于是医疗申报上:一个只持 cfo 的账号在 module.hr.edit 那一行就被拒,
--   根本到不了这里。
--
-- 【raiser 那条腿什么时候一起被豁免】只有当提单的人【也是】这个人。
-- 本函数的条件②已经要求"主角就是我",所以 forbid_self_approval 里
-- "raiser 腿成立 且 例外成立"只可能是"我提的、说的也是我"—— 一张我替别人
-- 提的单,条件②不成立,raiser 那一句照拒。
--
-- 【为什么返回 boolean 而这一次是对的】AGENTS.md 那条规矩管的是【拒绝】被表示成
-- 一个会被 COALESCE 掉的值。这里的值是一次【豁免】,它的 NULL 方向是安全的
-- (NULL 读成"不豁免")—— 而且本函数按构造不返回 NULL(见函数体)。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1a-higher-decides-lower-and-the-flagged-self.sql.

CREATE OR REPLACE FUNCTION public.self_approval_exception(p_subject_type text, p_subject_employee uuid, p_user uuid, p_level2_role text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
               p_subject_type IN ('expense_claim', 'medical_claim')
           AND p_subject_employee IS NOT NULL
           AND p_user IS NOT NULL
           AND p_level2_role IS NOT NULL
           AND account_person(p_user) = p_subject_employee
           AND EXISTS (SELECT 1 FROM real_role_holders(p_level2_role) h WHERE h.user_id = p_user),
           false);
$function$;

COMMENT ON FUNCTION public.self_approval_exception(text, uuid, uuid, text) IS
'APR-ROUTE-1(R2):"不许自己批自己"的唯一例外 —— 单据是 expense_claim 或 medical_claim、这个账号属于单据说的那个人、并且它此刻是二级审批角色的真持有人。永不返回 NULL。它不放宽任何模块门:能不能走到这一步仍由决定函数自己的 require_permission 决定。approval_log 上的 approval_log_self_decided_scope 是同一句话的第二道保险。EXECUTE 已从 authenticated 收回。';
