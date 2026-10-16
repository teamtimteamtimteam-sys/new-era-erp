-- db/functions/record_incident_update.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q10,Tim):【一件事故之后的一个事实】—— 事故那一行不改,这里加一行(incident_updates)。
--   module.safety.edit(记事故的同一个码)。返回 {update_id, kind}。
--
--   nea_notified / report_submitted —— 只对【现在】要通报的事故(更正过的值说了算,incident_current_all)收(INCIDENT_NOT_NEA_REPORTABLE|<编号>);
--     什么时候必填(INCIDENT_UPDATE_TIME_REQUIRED)、不在未来(INCIDENT_UPDATE_TIME_IN_FUTURE)、不早于事故(INCIDENT_UPDATE_BEFORE_INCIDENT);
--     编号 / 怎么通报的可选。每件各一行(INCIDENT_ALREADY_RECORDED|<种类>)。两者之间不规定先后(没有人裁过)。
--   closed —— 一句总结必填(INCIDENT_CLOSE_SUMMARY_REQUIRED);每件一行。关闭不清掉两条 NEA 提醒:法定的义务不因"关闭"而结束。
--   correction —— 关闭之后不收(INCIDENT_CLOSED|<编号>);字段只认七个(INCIDENT_CORRECTION_FIELD_INVALID|<字段>);理由必填
--     (INCIDENT_CORRECTION_REASON_REQUIRED);新值按字段判(INCIDENT_CORRECTION_VALUE_INVALID|<字段>):种类在清单里而且启用着、时刻读得出来
--     而且不在未来(INCIDENT_TIME_IN_FUTURE)、文字不是空白、时长是 ≥ 0 的数、通报是 true / false;与现在的值相同就不是一次更正
--     (INCIDENT_CORRECTION_NO_CHANGE|<字段>)。新值存成规范的字(时刻 → ISO,布尔 → true / false),读的一侧照它转回去。
--   同一件事故的两次更新排队(advisory lock),于是"每件一行"与"与现在的值相同"不会被并发绕过(部分唯一索引是第二道)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.record_incident_update(p_incident_id uuid, p_kind text, p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_reference text DEFAULT NULL::text, p_field text DEFAULT NULL::text, p_new_value text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_summary text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_cur   record;
    v_new   text;
    v_old   text;
    v_ts    timestamptz;
    v_num   numeric;
    v_id    bigint;
BEGIN
    PERFORM require_permission('module.safety.edit');
    IF p_incident_id IS NULL OR NOT EXISTS (SELECT 1 FROM incidents WHERE id = p_incident_id) THEN
        RAISE EXCEPTION 'INCIDENT_NOT_FOUND|%', COALESCE(p_incident_id::text, '?');
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('incident_update_' || p_incident_id::text)::bigint);
    SELECT * INTO v_cur FROM incident_current_all c WHERE c.id = p_incident_id;

    IF p_kind IS NULL OR p_kind NOT IN ('nea_notified', 'report_submitted', 'closed', 'correction') THEN
        RAISE EXCEPTION 'INCIDENT_UPDATE_KIND_INVALID|%', COALESCE(p_kind, '?');
    END IF;

    IF p_kind IN ('nea_notified', 'report_submitted') THEN
        IF NOT v_cur.nea_reportable THEN
            RAISE EXCEPTION 'INCIDENT_NOT_NEA_REPORTABLE|%', v_cur.code;
        END IF;
        IF p_occurred_at IS NULL THEN
            RAISE EXCEPTION 'INCIDENT_UPDATE_TIME_REQUIRED';
        END IF;
        IF p_occurred_at > now() THEN
            RAISE EXCEPTION 'INCIDENT_UPDATE_TIME_IN_FUTURE';
        END IF;
        IF p_occurred_at < v_cur.occurred_at THEN
            RAISE EXCEPTION 'INCIDENT_UPDATE_BEFORE_INCIDENT|%', to_char(v_cur.occurred_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
        END IF;
        IF EXISTS (SELECT 1 FROM incident_updates WHERE incident_id = p_incident_id AND kind = p_kind) THEN
            RAISE EXCEPTION 'INCIDENT_ALREADY_RECORDED|%', p_kind;
        END IF;
        INSERT INTO incident_updates (incident_id, kind, occurred_at, reference, recorded_by)
        VALUES (p_incident_id, p_kind, p_occurred_at, NULLIF(btrim(COALESCE(p_reference, '')), ''), v_user)
        RETURNING id INTO v_id;
        RETURN jsonb_build_object('update_id', v_id, 'kind', p_kind);
    END IF;

    IF p_kind = 'closed' THEN
        IF p_summary IS NULL OR btrim(p_summary) = '' THEN
            RAISE EXCEPTION 'INCIDENT_CLOSE_SUMMARY_REQUIRED';
        END IF;
        IF v_cur.closed_at IS NOT NULL THEN
            RAISE EXCEPTION 'INCIDENT_ALREADY_RECORDED|closed';
        END IF;
        INSERT INTO incident_updates (incident_id, kind, summary, recorded_by)
        VALUES (p_incident_id, 'closed', btrim(p_summary), v_user)
        RETURNING id INTO v_id;
        RETURN jsonb_build_object('update_id', v_id, 'kind', 'closed');
    END IF;

    -- correction
    IF v_cur.closed_at IS NOT NULL THEN
        RAISE EXCEPTION 'INCIDENT_CLOSED|%', v_cur.code;
    END IF;
    IF p_field IS NULL OR p_field NOT IN ('kind_code', 'occurred_at', 'what_happened', 'immediate_action', 'responsible_name',
                                          'duration_min', 'nea_reportable') THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_FIELD_INVALID|%', COALESCE(p_field, '?');
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_REASON_REQUIRED';
    END IF;
    v_new := NULLIF(btrim(COALESCE(p_new_value, '')), '');
    IF v_new IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_VALUE_INVALID|%', p_field;
    END IF;
    IF p_field = 'kind_code' THEN
        IF NOT EXISTS (SELECT 1 FROM incident_kinds k WHERE k.code = v_new) THEN
            RAISE EXCEPTION 'INCIDENT_KIND_UNKNOWN|%', v_new;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM incident_kinds k WHERE k.code = v_new AND k.is_active) THEN
            RAISE EXCEPTION 'INCIDENT_KIND_INACTIVE|%', v_new;
        END IF;
        v_old := v_cur.kind_code;
    ELSIF p_field = 'occurred_at' THEN
        BEGIN
            v_ts := v_new::timestamptz;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'INCIDENT_CORRECTION_VALUE_INVALID|occurred_at';
        END;
        IF v_ts > now() THEN
            RAISE EXCEPTION 'INCIDENT_TIME_IN_FUTURE|%', to_char(v_ts AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
        END IF;
        v_new := to_char(v_ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
        v_old := to_char(v_cur.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    ELSIF p_field = 'duration_min' THEN
        BEGIN
            v_num := v_new::numeric;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'INCIDENT_CORRECTION_VALUE_INVALID|duration_min';
        END;
        IF v_num < 0 THEN
            RAISE EXCEPTION 'INCIDENT_CORRECTION_VALUE_INVALID|duration_min';
        END IF;
        v_new := v_num::text;
        v_old := v_cur.duration_min::text;
        IF v_cur.duration_min IS NOT NULL AND v_cur.duration_min = v_num THEN
            v_old := v_new;
        END IF;
    ELSIF p_field = 'nea_reportable' THEN
        IF lower(v_new) NOT IN ('true', 'false') THEN
            RAISE EXCEPTION 'INCIDENT_CORRECTION_VALUE_INVALID|nea_reportable';
        END IF;
        v_new := lower(v_new);
        v_old := v_cur.nea_reportable::text;
    ELSIF p_field = 'what_happened' THEN
        v_old := v_cur.what_happened;
    ELSIF p_field = 'immediate_action' THEN
        v_old := v_cur.immediate_action;
    ELSE
        v_old := v_cur.responsible_name;
    END IF;
    IF v_new IS NOT DISTINCT FROM v_old THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_NO_CHANGE|%', p_field;
    END IF;
    INSERT INTO incident_updates (incident_id, kind, field, new_value, reason, recorded_by)
    VALUES (p_incident_id, 'correction', p_field, v_new, btrim(p_reason), v_user)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('update_id', v_id, 'kind', 'correction', 'field', p_field);
END;
$function$;
