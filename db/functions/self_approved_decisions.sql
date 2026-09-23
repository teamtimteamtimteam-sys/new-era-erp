-- db/functions/self_approved_decisions.sql
-- APR-ROUTE-1(Tim 的 R2 · Q4):【每一次自批,一行】—— 自批报表的唯一数据来源。
--
-- 【它为什么存在】Tim 裁定二级审批角色的持有人可以决定他自己的报销单与医疗申报,
-- 而且是有意识地选了【可追溯】而不是【可防止】。可追溯要成立,就必须有一个地方
-- 让别人【看得见】每一次这样的决定 —— 一个只写进 approval_log、却没有任何屏幕
-- 读它的标记,与没有标记是同一件事(本仓库反复付账的"写得进、读不出")。
--
-- 【谁看得见】持 data.view_self_approvals 的人:admin · gm(MD,Vince)· auditor
-- (Tim 的 Q4)。★ 这一个码是【新铸的】,不借 module.finance.view / module.hr.view:
-- 后两者 finance 与 cfo 自己就持有 —— 也就是被这张表报告的那个人,
-- 用借来的码他就总是看得见自己被报告了什么,而 Tim 要的读者是另外那几位。
--
-- 【为什么是一支 DEFINER 函数,不是一张视图】approval_log 的读策略按 subject_type
-- 分门(报销 → module.finance.view,医疗 → module.hr.view)。一个持本码而不持
-- 那两个模块码的审计者,经由那张表会读到【0 行,而且不报错】—— 与"从来没人自批过"
-- 逐字相同。所以这里以属主身份读,而门只有一个:本码。
-- ★ 读者没有这个码时【RAISE】,不返回零行 —— 零行在这里有主,它的意思是
--   "没有人自批过",把拒绝也表示成零行就是把拒绝伪装成一个合法答案
--   (AGENTS.md「拒绝要用哪个值表示」)。
--
-- 【名字跟着单据走】(Standing decision 3)决定人与主角的【显示名】随行返回;
-- 别的员工属性一概不带。
--
-- ★ ROLE-1(2026-09-23):R2 扩到请假(只对 CFO),于是主角的 LATERAL 多一支 leave_requests ——
--   不加它,Tim 自批的假在报表上会有一个空白的主角。admin 不再持 data.view_self_approvals
--   (Tim 的 Q8:admin 只做系统管理),读者剩 gm 与 auditor。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1a-higher-decides-lower-and-the-flagged-self.sql.

CREATE OR REPLACE FUNCTION public.self_approved_decisions()
 RETURNS TABLE(seq bigint, decided_at timestamp with time zone, subject_type text, subject_id uuid, subject_code text, decision text, level smallint, actor_user_id uuid, actor_name text, subject_employee_id uuid, subject_name text, amount_ccy numeric, currency text, amount_base numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('data.view_self_approvals');

    RETURN QUERY
    SELECT a.seq, a.decided_at, a.subject_type, a.subject_id, a.subject_code, a.decision,
           a.level, a.actor_user_id,
           COALESCE(ae.legal_name, au.email::text, a.actor_user_id::text) AS actor_name,
           s.employee_id,
           se.legal_name,
           a.amount_ccy, a.currency, a.amount_base, a.note
      FROM approval_log a
      LEFT JOIN auth.users au ON au.id = a.actor_user_id
      LEFT JOIN employees ae ON ae.id = account_person(a.actor_user_id)
      LEFT JOIN LATERAL (
            SELECT c.employee_id FROM expense_claims c
             WHERE a.subject_type = 'expense_claim' AND c.id = a.subject_id
            UNION ALL
            SELECT m.employee_id FROM medical_claims m
             WHERE a.subject_type = 'medical_claim' AND m.id = a.subject_id
            UNION ALL
            SELECT l.employee_id FROM leave_requests l
             WHERE a.subject_type = 'leave_request' AND l.id = a.subject_id
      ) s ON true
      LEFT JOIN employees se ON se.id = s.employee_id
     WHERE a.self_decided
     ORDER BY a.seq DESC;
END;
$function$;

COMMENT ON FUNCTION public.self_approved_decisions() IS
'APR-ROUTE-1(R2 · Q4):自批报表 —— approval_log 里 self_decided 的每一行,带决定人与主角的显示名。门只有一个:data.view_self_approvals(ROLE-1 起:gm · auditor —— admin 不再持任何业务码);没有它就 RAISE,不返回零行(零行在这里的意思是"没有人自批过")。以属主身份读,因为 approval_log 的读策略按单据类型分门,一个只持本码的审计者经由那张表会静默读到零行。';
