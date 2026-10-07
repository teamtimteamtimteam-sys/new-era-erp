-- db/functions/guard_ceiling_check_append_only.sql
-- MES-3a(2026-10-06,MES-3a Step 0 Q10):receipt_ceiling_checks 只追加 —— 一次判法记下来就不改、不删。
--   UPDATE / DELETE / TRUNCATE 一律语句级拒(没有写策略时 authenticated 的 UPDATE / DELETE 在 RLS 那里是零行,行级触发器不会醒)。
--   STORAGE_CEILING_CHECK_APPEND_ONLY|<操作>。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.guard_ceiling_check_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'STORAGE_CEILING_CHECK_APPEND_ONLY|%', lower(TG_OP);
END;
$function$;
