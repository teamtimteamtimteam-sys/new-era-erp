-- db/functions/guard_work_order_history_append_only.sql
-- HISTORY-1(Tim 的 Q18):work_order_history 此前没有只增不改守卫。现在与另外 15 张同一个形状。
CREATE OR REPLACE FUNCTION public.guard_work_order_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'WORK_ORDER_HISTORY_IMMUTABLE|%', TG_OP;
END;
$function$;
