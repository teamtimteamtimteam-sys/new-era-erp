-- db/functions/record_incident_days_lost_correction.sql
-- ESG-2(Tim 2026-10-31 Q7):更正一件事故的误工天数(带理由;最后一次更正说了算)。与 record_incident_update 的 correction 同一套规矩:
--   要 module.safety.edit;关闭之后不收(INCIDENT_CLOSED|<编号>);理由必填(INCIDENT_CORRECTION_REASON_REQUIRED);
--   与现在的值相同(INCIDENT_CORRECTION_NO_CHANGE|days_lost);值要是 ≥ 0 的数(INCIDENT_DAYS_LOST_INVALID)。
--   另加一条:只在【有受伤的人】的事故上(INCIDENT_INJURY_NEEDS_PERSON —— 与 incidents_injury_needs_person 那条约束同一句)。
--   存进 incident_days_lost_corrections(健康数据,读要 data.view_health 或受伤的那名员工本人),不进 incident_updates(那张表人人可读)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.record_incident_days_lost_correction(p_incident_id uuid, p_days_lost numeric, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_i   incidents%ROWTYPE;
    v_cur numeric;
    v_id  bigint;
BEGIN
    PERFORM require_permission('module.safety.edit');
    SELECT * INTO v_i FROM incidents WHERE id = p_incident_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INCIDENT_NOT_FOUND|%', p_incident_id;
    END IF;
    IF EXISTS (SELECT 1 FROM incident_updates u WHERE u.incident_id = v_i.id AND u.kind = 'closed') THEN
        RAISE EXCEPTION 'INCIDENT_CLOSED|%', v_i.code;
    END IF;
    IF v_i.injured_employee_id IS NULL AND v_i.injured_person_name IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_INJURY_NEEDS_PERSON';
    END IF;
    IF p_days_lost IS NULL OR p_days_lost < 0 THEN
        RAISE EXCEPTION 'INCIDENT_DAYS_LOST_INVALID';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_REASON_REQUIRED';
    END IF;
    v_cur := COALESCE((SELECT d.days_lost FROM incident_days_lost_corrections d WHERE d.incident_id = v_i.id ORDER BY d.id DESC LIMIT 1),
                      v_i.days_lost);
    IF v_cur IS NOT DISTINCT FROM p_days_lost THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_NO_CHANGE|days_lost';
    END IF;
    INSERT INTO incident_days_lost_corrections (incident_id, days_lost, reason, recorded_by)
    VALUES (v_i.id, p_days_lost, btrim(p_reason), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('correction_id', v_id, 'incident_id', v_i.id);
END;
$function$;
