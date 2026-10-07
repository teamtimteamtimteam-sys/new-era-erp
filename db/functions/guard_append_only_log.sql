-- db/functions/guard_append_only_log.sql
-- MES-3b(2026-10-07,MES-3b Step 0 Q8 · Q20):label_prints 与 scan_events 只追加 —— 一行记下来就不改、不删。
--   UPDATE / DELETE / TRUNCATE 一律语句级拒(没有写策略时 authenticated 的 UPDATE / DELETE 在 RLS 那里是零行,行级触发器不会醒 ——
--   与 guard_ceiling_check_append_only 同一个理由)。APPEND_ONLY|<表>|<操作>。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.guard_append_only_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'APPEND_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
END;
$function$;
