-- db/functions/record_sample_event.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q7 · Q15,Tim):【记一件保管上的事】—— module.quality.edit,只追加。
--   sent_to_lab(实验室必填、要启用的;实验室那一侧的编号可选)· received_back(库位可选)· moved(库位必填)· disposed(理由必填)。
--   taken 只由 record_sample 写。时刻必填、不许晚于此刻、不许早于这份样品上一行的时刻(SAMPLE_EVENT_OUT_OF_ORDER)。
--   顺序:拿在手上(taken / received_back / moved)→ 送得出去、挪得动、处置得了;在实验室 → 只能拿回来或处置;处置之后什么都不能记。
--   早于留样日的处置照收(Q15),由 sample_rows.disposed_early 标出来。返回 {event_id, state}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.record_sample_event(p_sample_id uuid, p_event_kind text, p_occurred_at timestamp with time zone, p_laboratory_code text DEFAULT NULL::text, p_lab_reference text DEFAULT NULL::text, p_storage_location_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_sample samples%ROWTYPE;
    v_last   sample_events%ROWTYPE;
    v_state  text;
    v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_id     bigint;
BEGIN
    PERFORM require_permission('module.quality.edit');
    SELECT * INTO v_sample FROM samples WHERE id = p_sample_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SAMPLE_NOT_FOUND|%', COALESCE(p_sample_id::text, '?');
    END IF;
    IF p_event_kind IS NULL OR p_event_kind NOT IN ('sent_to_lab', 'received_back', 'moved', 'disposed') THEN
        RAISE EXCEPTION 'SAMPLE_EVENT_KIND_INVALID|%', COALESCE(p_event_kind, '?');
    END IF;
    IF p_occurred_at IS NULL THEN
        RAISE EXCEPTION 'SAMPLE_EVENT_TIME_REQUIRED';
    END IF;
    IF p_occurred_at > now() THEN
        RAISE EXCEPTION 'SAMPLE_EVENT_IN_FUTURE|%', v_sample.code;
    END IF;

    -- 最近那一行决定现在的状态(id 记先后)
    SELECT * INTO v_last FROM sample_events WHERE sample_id = p_sample_id ORDER BY id DESC LIMIT 1;
    v_state := CASE v_last.event_kind WHEN 'sent_to_lab' THEN 'at_lab' WHEN 'disposed' THEN 'disposed' ELSE 'held' END;
    IF v_state = 'disposed' THEN
        RAISE EXCEPTION 'SAMPLE_DISPOSED|%', v_sample.code;
    END IF;
    IF NOT ((v_state = 'held' AND p_event_kind IN ('sent_to_lab', 'moved', 'disposed'))
            OR (v_state = 'at_lab' AND p_event_kind IN ('received_back', 'disposed'))) THEN
        RAISE EXCEPTION 'SAMPLE_EVENT_NOT_ALLOWED|%|%|%', v_sample.code, v_state, p_event_kind;
    END IF;
    IF p_occurred_at < v_last.occurred_at THEN
        RAISE EXCEPTION 'SAMPLE_EVENT_OUT_OF_ORDER|%|%', v_sample.code, v_last.occurred_at;
    END IF;

    IF p_event_kind = 'sent_to_lab' THEN
        IF p_laboratory_code IS NULL THEN
            RAISE EXCEPTION 'SAMPLE_LAB_REQUIRED|%', v_sample.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM laboratories WHERE code = p_laboratory_code AND is_active) THEN
            RAISE EXCEPTION 'LAB_NOT_FOUND|%', p_laboratory_code;
        END IF;
    ELSIF p_laboratory_code IS NOT NULL OR NULLIF(btrim(COALESCE(p_lab_reference, '')), '') IS NOT NULL THEN
        RAISE EXCEPTION 'SAMPLE_LAB_ONLY_WHEN_SENT|%', v_sample.code;
    END IF;
    IF p_event_kind = 'moved' AND p_storage_location_id IS NULL THEN
        RAISE EXCEPTION 'SAMPLE_LOCATION_REQUIRED|%', v_sample.code;
    END IF;
    IF p_storage_location_id IS NOT NULL THEN
        IF p_event_kind NOT IN ('received_back', 'moved') THEN
            RAISE EXCEPTION 'SAMPLE_LOCATION_NOT_FOR_EVENT|%|%', v_sample.code, p_event_kind;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_storage_location_id AND is_active) THEN
            RAISE EXCEPTION 'LOCATION_NOT_FOUND|%', p_storage_location_id;
        END IF;
    END IF;
    IF p_event_kind = 'disposed' AND v_reason IS NULL THEN
        RAISE EXCEPTION 'SAMPLE_DISPOSAL_REASON_REQUIRED|%', v_sample.code;
    END IF;
    IF p_event_kind <> 'disposed' AND v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'SAMPLE_REASON_ONLY_WHEN_DISPOSED|%', v_sample.code;
    END IF;

    INSERT INTO sample_events (sample_id, event_kind, occurred_at, laboratory_code, lab_reference, storage_location_id,
                               reason, notes, created_by)
    VALUES (p_sample_id, p_event_kind, p_occurred_at, p_laboratory_code, NULLIF(btrim(COALESCE(p_lab_reference, '')), ''),
            p_storage_location_id, v_reason, NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('event_id', v_id, 'code', v_sample.code,
        'state', CASE p_event_kind WHEN 'sent_to_lab' THEN 'at_lab' WHEN 'disposed' THEN 'disposed' ELSE 'held' END);
END;
$function$
