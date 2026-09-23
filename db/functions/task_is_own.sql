CREATE OR REPLACE FUNCTION public.task_is_own(p_task_type text, p_owner_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(p_task_type = 'personal' AND p_owner_id = current_user_employee(), false);
$function$;

COMMENT ON FUNCTION public.task_is_own(text, uuid) IS
'APR-4(Tim 的 Q4):「自己的任务」的【唯一】定义 —— 私人任务,且归属人就是调用者这个人(current_user_employee(),按人认,一个人的几个账号算同一个人)。
按【这一行自己的两列】判,不回表查 —— 所以插入与更新的判据可以直接把手里这一行交给它。
★ 它不看 module.tasks.view:那一半由调用方(can_write_task、trg_tasks_guard_write、插入策略)各自要求 —— 这里只回答"这是不是你的",不回答"你能不能进任务模块"。
★ 为什么不是 created_by = 我:created_by 是账号空间、客户端写得动,伪造得出来;读的那一边(select 策略)也从来不看它。
★ 为什么不是"我是参与者":那会让一个只读的人改动别人的团队任务。团队任务一律要 module.tasks.edit。';
