-- db/functions/guard_history_no_truncate.sql
-- HISTORY-1(Tim 的 Q19):17 张领域历史表的 TRUNCATE 守卫。
-- 它们此前各有一条 BEFORE UPDATE/DELETE 的只增不改守卫(task_history 与 work_order_history 连那条都没有,
-- 见 Q18),但【没有一张】挡得住 TRUNCATE —— 行级触发器对 TRUNCATE 不响,而平台默认把 TRUNCATE
-- 授给了 authenticated。一个语句级 BEFORE TRUNCATE 触发器补上这一格。
CREATE OR REPLACE FUNCTION public.guard_history_no_truncate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'HISTORY_TRUNCATE_FORBIDDEN|%', TG_TABLE_NAME;
END;
$function$;
