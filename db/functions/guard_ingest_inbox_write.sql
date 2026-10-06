-- db/functions/guard_ingest_inbox_write.sql
-- MES-1(2026-10-06,规格 §6.4;MES-1 Step 0 Q11 · Q15,Tim):收件箱只追加 —— 唯一会变的是【转换】那几列。
--   ① DELETE / TRUNCATE 一律拒(INGEST_LOG_APPEND_ONLY|ingest_inbox|<操作>),语句级。规格 §6.4:失败的转换不丢。
--   ② 转换成功或丢弃之后冻住(INBOX_ROW_FROZEN|<id>)。
--   ③ 只有 status · transformed_with · transform_result · error_code · attempts · last_attempt_at · last_attempt_by ·
--      discarded_at · discarded_by · discard_reason 会变;网关送来的那些(网关、流、序号、设备、类、payload、哈希、现场时间、
--      收到时刻)一个字都不改(INBOX_ONLY_STATUS_CHANGES)。
--   ④ 而且只在处理 / 重试 / 丢弃那三支函数设的事务级标记下(INBOX_THROUGH_FUNCTION_ONLY)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.guard_ingest_inbox_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'INGEST_LOG_APPEND_ONLY|ingest_inbox|%', lower(TG_OP);
    END IF;
    IF OLD.status IN ('transformed', 'discarded') THEN
        RAISE EXCEPTION 'INBOX_ROW_FROZEN|%', OLD.id;
    END IF;
    IF COALESCE(current_setting('evoltrya.ingest_ctx', true), '') <> 'inbox_process' THEN
        RAISE EXCEPTION 'INBOX_THROUGH_FUNCTION_ONLY';
    END IF;
    IF (to_jsonb(NEW) - 'status' - 'transformed_with' - 'transform_result' - 'error_code' - 'attempts'
                      - 'last_attempt_at' - 'last_attempt_by' - 'discarded_at' - 'discarded_by' - 'discard_reason')
       IS DISTINCT FROM
       (to_jsonb(OLD) - 'status' - 'transformed_with' - 'transform_result' - 'error_code' - 'attempts'
                      - 'last_attempt_at' - 'last_attempt_by' - 'discarded_at' - 'discarded_by' - 'discard_reason') THEN
        RAISE EXCEPTION 'INBOX_ONLY_STATUS_CHANGES|%', OLD.id;
    END IF;
    RETURN NEW;
END;
$function$;
