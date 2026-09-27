-- db/functions/salary_change_deciders.sql
-- APR-9(2026-09-27,grilling Q2 · Q4):一张【提单人为 p_raiser、主角为 p_employee_id】的调薪申请,谁批得动。
--   = 真持有(real_role_grants:未撤销 · 已确认 · 未封 · 未删)pay_decision_code(提单人, 员工) 那个码
--     且 module.hr.view 且 data.view_pay 的账号,减去提单人与主角(self_leg,按人认)。
-- 它与 approval_deciders 同一个形状,只是【码】由 pay_decision_code 按人给出,而不是按级从 approval_chain_gates 取 ——
-- 这条链不在那本名册里(Q2),所以不能借 approval_deciders;"谁批得了加薪"仍只有 pay_decision_code 一份定义。
-- R2 的自批例外永远不覆盖调薪(self_approval_exception 不认 salary_change_request),所以这里没有那一支。
-- 读者:submit_salary_change_request(提单人之外没人 → SALARY_CHANGE_NO_OTHER_DECIDER)· 迁移自证 ·
-- salary_change_requests_visible 不读它(它只答"我"能不能批)。person_key 按人认,同一个人的两个账号只算一个。
-- EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_change_deciders(p_raiser uuid, p_employee_id uuid)
 RETURNS TABLE(user_id uuid, person_key text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH need AS (
        SELECT unnest(ARRAY[pay_decision_code(p_raiser, p_employee_id), 'module.hr.view', 'data.view_pay']) AS code
    ),
    real_perm AS (
        SELECT DISTINCT rp.permission_code, rg.user_id
          FROM role_permissions rp
          JOIN roles r ON r.id = rp.role_id
         CROSS JOIN LATERAL real_role_grants(r.code) rg
    ),
    cand AS (
        SELECT DISTINCT pp.user_id FROM real_perm pp
         WHERE NOT EXISTS (
                 SELECT 1 FROM need n
                  WHERE NOT EXISTS (SELECT 1 FROM real_perm q
                                     WHERE q.user_id = pp.user_id AND q.permission_code = n.code))
    )
    SELECT c.user_id, COALESCE(account_person(c.user_id)::text, 'account:' || c.user_id::text)
      FROM cand c
     WHERE self_leg(p_raiser, p_employee_id, c.user_id) = 'none'
$function$;
