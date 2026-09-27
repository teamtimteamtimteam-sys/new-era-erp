-- db/functions/review_approval_code.sql
-- ROLE-1(Tim 的矩阵,2026-09-23):一张绩效评估【要哪一个码才批得了】—— 唯一的定义。
--
-- 【规则,原样】绩效评估由 cco 做、CFO 批;Tim 自己的评估由 cco 批。
-- Step 0 的 grilling 量出来还有第二种情形:Choo Er 的上级(manager_id)是 Tim,
-- 所以她的评估是 Tim 以评估人身份【提交】的 —— 那时 CFO 是提交人,自批拒绝会挡住他。
-- 于是 Tim 的 Q5 裁定:**CFO 批;CFO 是提交人【或】主角时,cco 批。**
--
--   · 一般情形            → 'action.approve_review'(cfo 持有)
--   · CFO 是提交人或主角  → 'action.hr_reviews'   (cco 持有 —— 做评估的那个码)
--
-- "CFO" = finance_settings.approval_level2_role_code 那个角色的【真持有人】,按【人】认
-- (account_person —— Tim 的两个账号是一个人)。与 R2 的 self_approval_exception
-- 用同一个判据,不另写一份"谁是 CFO"。二级角色没设 → 一般情形。
--
-- 【两个读者】approve_review(门)与评估详情页(按钮可不可按、为什么)。
-- 一份定义两个读者 —— 页面【不】在 TypeScript 里重算这条规矩(AGENTS.md 的预览规则)。
--
-- 【永不返回 NULL】它的返回值直接喂给 require_permission;NULL 会变成一次
-- "谁都没有的码"的拒绝,读起来像权限问题,其实是这里写错了。
--
-- ★ APR-9(2026-09-27,grilling Q2):**规则搬进了 pay_decision_code,这里只委托。** 调薪申请要问的是同一句话
--   (CFO 是当事人 → cco),两份实现就是两份会漂开的"谁批得了加薪"。本函数的签名、返回值、两个读者一个字没变。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.review_approval_code(p_submitted_by uuid, p_employee_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT pay_decision_code(p_submitted_by, p_employee_id);
$function$;

COMMENT ON FUNCTION public.review_approval_code(uuid, uuid) IS
'ROLE-1(Tim 的矩阵 · Q5):批一张绩效评估要哪一个码 —— CFO(二级审批角色的真持有人,按人认)是提交人或主角时 action.hr_reviews(cco),否则 action.approve_review(cfo)。两个读者:approve_review 的门与评估详情页。永不返回 NULL。★ APR-9:规则本身住在 pay_decision_code(调薪申请问同一句话),本函数只委托。';
