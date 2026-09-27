-- db/functions/my_document_decisions.sql
-- EMP-SELF-1(G2,Tim 的 Q4 · Q5,2026-09-27):员工在 /me 上看见自己的请假、医疗申报、报销【是谁决定的、为什么】。
--
-- 【读单据本身】decided_by · decided_at · decision_notes —— 不读 approval_log(它仍按权限开放,Tim 的 Q4 at EMP-SELF-0)。
-- 【为什么是属主权限】决定人是【另一个】员工:employees 的 RLS 只给非 HR 读者他自己那一行,
--   所以 INVOKER 下名字永远是空的。本函数只替调用者打开一件事 —— 他【自己的】单据上那位决定人的显示名。
-- 【只给自己的】employee_id = current_user_employee();没有员工档案的调用者(NULL)→ 0 行,不是全部。
-- 【显示的是人,不是账号】account_person(decided_by) → preferred_name,否则 legal_name(与 ActorName.tsx 同一条)。
--   于是 tim@ 这个附加账号做的决定显示成它主人的名字(APR-ROUTE-1 Batch B)。
-- 【self_decided】决定人这个人就是单据的主角 —— R2 那张被标记的自批,或员工自己撤掉的假;由单据推出,不读留痕。
-- 【已取消的假】cancel_leave_request 把取消人与理由写进同样三列(Tim 的 Q3:按状态标注,不改表)。
--   撤回的报销 / 医疗申报没有 decided_by,所以不出现在这里。
--
-- NOTE: introduced by db/migrations/2026-09-27-emp-self1-find-see-and-withdraw-your-own.sql.

CREATE OR REPLACE FUNCTION public.my_document_decisions()
 RETURNS TABLE(kind text, doc_id uuid, decider text, decided_at timestamp with time zone, decision_notes text, self_decided boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH me AS (SELECT current_user_employee() AS eid),
    docs AS (
        SELECT 'leave_request'::text AS kind, l.id, l.employee_id, l.decided_by, l.decided_at, l.decision_notes
          FROM leave_requests l, me
         WHERE l.employee_id = me.eid AND l.deleted_at IS NULL AND l.decided_by IS NOT NULL
        UNION ALL
        SELECT 'medical_claim', m.id, m.employee_id, m.decided_by, m.decided_at, m.decision_notes
          FROM medical_claims m, me
         WHERE m.employee_id = me.eid AND m.deleted_at IS NULL AND m.decided_by IS NOT NULL
        UNION ALL
        SELECT 'expense_claim', c.id, c.employee_id, c.decided_by, c.decided_at, c.decision_notes
          FROM expense_claims c, me
         WHERE c.employee_id = me.eid AND c.decided_by IS NOT NULL
    )
    SELECT d.kind, d.id,
           (SELECT COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name)
              FROM employees e WHERE e.id = account_person(d.decided_by)),
           d.decided_at, d.decision_notes,
           COALESCE(account_person(d.decided_by) = d.employee_id, false)
      FROM docs d
$function$;
