-- db/functions/guard_ingest_transmissions_write.sql
-- MES-1(2026-10-06,MES-1 Step 0 Q7 · Q8,Tim):传输日志只追加 —— 唯一的例外是两种桶的四个计数列,而且只经 ingest_submit。
--   ① DELETE / TRUNCATE 一律拒(INGEST_LOG_APPEND_ONLY|ingest_transmissions|<操作>),语句级。
--   ② 一次调用的那一行(kind = call)定下就不改。
--   ③ 桶(heartbeat_hour · rejected_overflow):只有 bucket_count · bucket_bytes · bucket_last_at · bucket_first_at 会变;
--      count / bytes / last_at 只许变大或不变,first_at 只许变小或不变(INGEST_BUCKET_ONLY_GROWS);
--      而且只在 ingest_submit 自己设的那个事务级标记下(INGEST_BUCKET_THROUGH_FUNCTION_ONLY)。
--      标记是事务内的 set_config(…, true),由函数在那一句 upsert 前后设与清 —— 别的路径(哪怕是属主手写一句 UPDATE)都碰不到。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.guard_ingest_transmissions_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'INGEST_LOG_APPEND_ONLY|ingest_transmissions|%', lower(TG_OP);
    END IF;
    IF OLD.kind = 'call' THEN
        RAISE EXCEPTION 'INGEST_LOG_APPEND_ONLY|ingest_transmissions|update';
    END IF;
    IF COALESCE(current_setting('evoltrya.ingest_ctx', true), '') <> 'ingest_submit' THEN
        RAISE EXCEPTION 'INGEST_BUCKET_THROUGH_FUNCTION_ONLY';
    END IF;
    IF (to_jsonb(NEW) - 'bucket_count' - 'bucket_bytes' - 'bucket_first_at' - 'bucket_last_at')
       IS DISTINCT FROM (to_jsonb(OLD) - 'bucket_count' - 'bucket_bytes' - 'bucket_first_at' - 'bucket_last_at')
       OR NEW.bucket_count < OLD.bucket_count
       OR NEW.bucket_bytes < OLD.bucket_bytes
       OR NEW.bucket_last_at < OLD.bucket_last_at
       OR NEW.bucket_first_at > OLD.bucket_first_at THEN
        RAISE EXCEPTION 'INGEST_BUCKET_ONLY_GROWS';
    END IF;
    RETURN NEW;
END;
$function$;
