-- db/functions/is_reviewer_of.sql
-- 调用者是不是这一行的评估人。【任何一边为 NULL 都判 false】——
-- 直接写 reviewer_employee_id = current_user_employee() 会在任一边为 NULL 时得到 NULL,
-- 让 NOT(... OR NULL) 变成 NULL、守卫整个放行。没有指派评估人的评估曾因此人人可写。
-- 【全库只此一处】做这个判断。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.is_reviewer_of(p_reviewer_employee_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 任何一边是 NULL 都判 false。【全库只此一处】判断"我是不是这一行的评估人"。
    SELECT p_reviewer_employee_id IS NOT NULL
       AND current_user_employee() IS NOT NULL
       AND p_reviewer_employee_id = current_user_employee();
$function$
;