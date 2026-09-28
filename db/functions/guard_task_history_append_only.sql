-- db/functions/guard_task_history_append_only.sql
-- HISTORY-1(Tim 的 Q18):task_history 此前是 17 张历史表里两张【没有】只增不改守卫的之一
-- (HISTORY-0 §A.3:pg_stat 记着 n_tup_upd = 2、n_tup_del = 6)。现在与另外 15 张同一个形状。
CREATE OR REPLACE FUNCTION public.guard_task_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'TASK_HISTORY_IMMUTABLE|%', TG_OP;
END;
$function$;
