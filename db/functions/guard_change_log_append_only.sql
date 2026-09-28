-- db/functions/guard_change_log_append_only.sql
-- HISTORY-1:change_log 的只增不改守卫。BEFORE UPDATE/DELETE(行级)与 BEFORE TRUNCATE(语句级)共用。
--
-- 【唯一放行的形状】匿名化涂抹(Tim 的 Q11):redacted_at 从空变成有值,且
--   ① 除 old / new / redacted_at 之外的【每一列】逐字不变 —— 比的是整行的 jsonb 去掉这三列,
--     所以本表以后加的列自动落在"不许改"那一边(与 reject_employment_history_mutation 的抬头同一条);
--   ② old 与 new 各自只许把【允许涂抹的列】(change_log_redactable_columns)改成 null,
--     键集合不许增减(change_log_redaction_ok)。
-- 其余一切 UPDATE、每一次 DELETE、每一次 TRUNCATE 都抛 CHANGE_LOG_IMMUTABLE。
-- 【判据按形状,不按会话标记】一个会话标记谁都设得了;一个形状只有涂抹那一种写得出来。
CREATE OR REPLACE FUNCTION public.guard_change_log_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.redacted_at IS NULL AND NEW.redacted_at IS NOT NULL
           AND (to_jsonb(NEW) - 'old' - 'new' - 'redacted_at') = (to_jsonb(OLD) - 'old' - 'new' - 'redacted_at')
           AND change_log_redaction_ok(OLD.table_name, OLD.old, NEW.old)
           AND change_log_redaction_ok(OLD.table_name, OLD.new, NEW.new)
        THEN
            RETURN NEW;
        END IF;
    END IF;
    RAISE EXCEPTION 'CHANGE_LOG_IMMUTABLE|%', TG_OP;
END;
$function$;
