-- db/views/employee_lookup.sql
-- FIX-2a(2026-09-05)· 跨模块【查名】视图。
-- ★ 暴露面【就是】下面的列清单。加一列等于扩一次权 —— 连着 db/fixtures/194 一起想。
-- 不变量:本视图只改【行】谓词;每一列原样保留它已有的 data.* 遮蔽。
-- NOTE: introduced by db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql.

CREATE VIEW public.employee_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    preferred_name,
    legal_name,
    user_id,
    deleted_at
   FROM employees e
  WHERE has_permission('module.hr.view'::text) OR has_permission('module.finance.view'::text);

COMMENT ON VIEW public.employee_lookup IS
    'FIX-2a:员工的【查名】视图 —— id / 工号 / 称呼名 / 法定名 / 登录账号。Tim 的 Q2 裁定:只有名字。付款、费用与薪资三处要把一份单据指向一个人。【没有】monthly_salary / identity_no / work_pass_* / residency_status / department_id / position_id / hire_date / separation_* / work_email / work_phone —— 那些才是人事事实,而 data.view_pay 与 data.view_identity 管着它们。行谓词 hr.view OR finance.view。与 ActorName 的分工:那一个答"谁做的",这一张答"这份单据指向谁"。';

GRANT SELECT ON public.employee_lookup TO authenticated;
