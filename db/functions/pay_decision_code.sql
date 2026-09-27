-- db/functions/pay_decision_code.sql
-- APR-9(2026-09-27,grilling Q2):**一次改月薪的决定,要哪一个码才批得了** —— 唯一的定义。
-- 两个读者的规则原来只写在 review_approval_code 里;调薪申请落地,它搬到这里,review_approval_code 委托过来
-- (APR-3 把分档那一个 >= 搬进 approval_level_at 的同一个手法:一份判据,旧入口原样保留)。
--
-- 【规则,原样】(ROLE-1 Tim 的 Q5;APR-9 确认对调薪申请同样成立)
--   · 一般情形                       → 'action.approve_review'(cfo 持有)
--   · CFO 这个【人】是提单人或主角    → 'action.hr_reviews'   (cco 持有)
-- "CFO" = finance_settings.approval_level2_role_code 那个角色的【真持有人】,按【人】认(account_person ——
-- Tim 的两个账号 tim@ / admin@ 是同一个人)。二级角色没设 → 一般情形。
-- 提单人 = 评估的 submitted_by / 调薪申请的 created_by;主角 = 被评估 / 被调薪的员工。
--
-- 【读者】review_approval_code(→ approve_review 与评估详情页)· decide_salary_change_request(门)·
-- salary_change_deciders(提交时"别人批得动吗"与迁移自证)· salary_change_requests_visible(按钮灰不灰)。
-- 【永不返回 NULL】返回值直接喂给 require_permission。
-- 【为什么 DEFINER 且收权】它读 real_role_holders / account_person(账号 ↔ 员工的对照);EXECUTE 从
-- authenticated 收回,屏幕经 review_approval_code(本来就给)或 salary_change_requests_visible 问它。
--
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.pay_decision_code(p_raiser uuid, p_employee_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN EXISTS (
                SELECT 1
                  FROM finance_settings fs
                 CROSS JOIN LATERAL real_role_holders(fs.approval_level2_role_code) h
                 WHERE fs.approval_level2_role_code IS NOT NULL
                   AND account_person(h.user_id) IS NOT NULL
                   AND (account_person(h.user_id) = p_employee_id
                        OR account_person(h.user_id) = account_person(p_raiser)))
           THEN 'action.hr_reviews'
           ELSE 'action.approve_review'
           END;
$function$;

COMMENT ON FUNCTION public.pay_decision_code(uuid, uuid) IS
'APR-9(grilling Q2):一次改月薪的决定(绩效评估的批准、调薪申请的决定)要哪一个码 —— CFO(二级审批角色的真持有人,按人认)是提单人或主角时 action.hr_reviews(cco),否则 action.approve_review(cfo)。唯一的定义;review_approval_code 委托给它。永不返回 NULL。EXECUTE 已从 authenticated 收回。';
