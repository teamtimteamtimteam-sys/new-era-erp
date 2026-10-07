-- db/functions/correct_run_event.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q29,Tim):【更正一件异常事件】—— 不改原行,落一条新的指回它(newest wins)。
--   持 action.processing_aftercare。理由必填(RUN_EVENT_CORRECTION_REASON_REQUIRED);只能更正链的末端(RUN_EVENT_SUPERSEDED);
--   p_withdraw = true 撤回这件事(记错了一件不存在的事 —— 五样照抄原行,withdrawn 为真);否则五样按新值、过同一份判据。
--   加工单必须已提交、没回滚。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.correct_run_event(p_event_id bigint, p_event_type text, p_occurred_at timestamp with time zone, p_duration_min numeric, p_action_taken text, p_responsible_person text, p_notes text, p_withdraw boolean, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run  processing_runs%ROWTYPE;
    v_orig processing_run_events%ROWTYPE;
    v_id   bigint;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_orig FROM processing_run_events WHERE id = p_event_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_EVENT_NOT_FOUND|%', p_event_id;
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = v_orig.run_id FOR UPDATE;
    IF v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.code;
    END IF;
    IF EXISTS (SELECT 1 FROM processing_run_events x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'RUN_EVENT_SUPERSEDED|%', v_orig.id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'RUN_EVENT_CORRECTION_REASON_REQUIRED';
    END IF;
    IF COALESCE(p_withdraw, false) THEN
        INSERT INTO processing_run_events (run_id, event_type_code, occurred_at, duration_min, action_taken, responsible_person, notes,
                                           withdrawn, corrects_id, correction_reason)
        VALUES (v_orig.run_id, v_orig.event_type_code, v_orig.occurred_at, v_orig.duration_min, v_orig.action_taken,
                v_orig.responsible_person, v_orig.notes, true, v_orig.id, btrim(p_reason))
        RETURNING id INTO v_id;
    ELSE
        PERFORM run_event_check(p_event_type, p_occurred_at, p_duration_min, p_action_taken, p_responsible_person);
        INSERT INTO processing_run_events (run_id, event_type_code, occurred_at, duration_min, action_taken, responsible_person, notes,
                                           corrects_id, correction_reason)
        VALUES (v_orig.run_id, p_event_type, p_occurred_at, p_duration_min, btrim(p_action_taken), btrim(p_responsible_person),
                NULLIF(btrim(COALESCE(p_notes, '')), ''), v_orig.id, btrim(p_reason))
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$function$
