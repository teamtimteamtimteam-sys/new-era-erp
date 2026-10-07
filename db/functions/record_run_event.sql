-- db/functions/record_run_event.sql
-- MES-4a(2026-10-07,规格 §3.1 · §5;MES-4a Step 0 Q15 · Q34,Tim):【给一炉记一件异常】—— 逐件记。
--   持 action.processing_aftercare。加工单必须已提交、没回滚(RUN_NOT_COMMITTED)。种类必须是字典里启用着的(RUN_EVENT_TYPE_UNKNOWN);
--   时刻必填(RUN_EVENT_TIME_REQUIRED);时长不为负(RUN_EVENT_DURATION_INVALID);做了什么、谁负责必填(RUN_EVENT_ACTION_REQUIRED ·
--   RUN_EVENT_RESPONSIBLE_REQUIRED)。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_run_event(p_run_id uuid, p_event_type text, p_occurred_at timestamp with time zone, p_duration_min numeric, p_action_taken text, p_responsible_person text, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run processing_runs%ROWTYPE;
    v_id  bigint;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    PERFORM run_event_check(p_event_type, p_occurred_at, p_duration_min, p_action_taken, p_responsible_person);
    INSERT INTO processing_run_events (run_id, event_type_code, occurred_at, duration_min, action_taken, responsible_person, notes)
    VALUES (p_run_id, p_event_type, p_occurred_at, p_duration_min, btrim(p_action_taken), btrim(p_responsible_person),
            NULLIF(btrim(COALESCE(p_notes, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
