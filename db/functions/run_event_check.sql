-- db/functions/run_event_check.sql
-- MES-4a(2026-10-07,MES-4a Step 0 Q15,Tim):【一件异常事件的五样说得通吗】—— 一份判据,两个调用方(record_run_event · correct_run_event)。
--   种类是字典里启用着的(RUN_EVENT_TYPE_UNKNOWN|<码>)· 时刻必填(RUN_EVENT_TIME_REQUIRED)· 时长为空或不为负(RUN_EVENT_DURATION_INVALID)·
--   做了什么(RUN_EVENT_ACTION_REQUIRED)· 谁负责(RUN_EVENT_RESPONSIBLE_REQUIRED)。
--   【内层】只读事件种类字典,没有调用者检查;EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.run_event_check(p_event_type text, p_occurred_at timestamp with time zone, p_duration_min numeric, p_action_taken text, p_responsible_person text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM processing_event_types t WHERE t.code = p_event_type AND t.is_active) THEN
        RAISE EXCEPTION 'RUN_EVENT_TYPE_UNKNOWN|%', COALESCE(p_event_type, '?');
    END IF;
    IF p_occurred_at IS NULL THEN
        RAISE EXCEPTION 'RUN_EVENT_TIME_REQUIRED';
    END IF;
    IF p_duration_min IS NOT NULL AND p_duration_min < 0 THEN
        RAISE EXCEPTION 'RUN_EVENT_DURATION_INVALID|%', p_duration_min;
    END IF;
    IF p_action_taken IS NULL OR btrim(p_action_taken) = '' THEN
        RAISE EXCEPTION 'RUN_EVENT_ACTION_REQUIRED';
    END IF;
    IF p_responsible_person IS NULL OR btrim(p_responsible_person) = '' THEN
        RAISE EXCEPTION 'RUN_EVENT_RESPONSIBLE_REQUIRED';
    END IF;
END;
$function$
