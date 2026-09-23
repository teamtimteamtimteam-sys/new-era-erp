-- db/functions/current_user_employee.sql
-- 当前会话的账号是哪一名员工 —— 所有"本人行"策略与自助路径的主语。
--
-- ★ APR-ROUTE-1 Batch B(2026-09-23,Tim 的 R3 · Q6/Q7):从此它就是
--   account_person(auth.uid())。"这个账号是谁"只有 account_person 一份定义,
--   它先查主账号、再回落到 employee_accounts —— 于是一个人的第二个账号
--   得到的是【同一名员工】,看得见他自己的 /me,而自批拒绝把它当成同一个人。
--   ★ account_person 已从 authenticated 收回 EXECUTE;本函数是 DEFINER,
--     以属主身份调用它,所以 RLS 策略与页面照常工作。
--   ☞ 此前的函数体是 `SELECT e.id FROM employees e WHERE e.user_id = auth.uid()
--     AND e.deleted_at IS NULL LIMIT 1` —— 它正是 account_person 的主账号那一支。

CREATE OR REPLACE FUNCTION public.current_user_employee()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT account_person(auth.uid());
$function$;
