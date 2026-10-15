-- db/functions/correct_equipment_downtime.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3 · Q6,Tim):【更正一段停机】—— 起止时刻、原因代号与说明。门 module.processing.edit。
--   取代 U1-B 的直连 UPDATE(Tim 的 UNBLOCK-1 Q15 说"更正走表上的 UPDATE 策略" —— 那条策略本刀拿掉,更正改走本函数;
--   变更记录照旧留着旧值,因为写的仍是那一行)。作废照旧只经 void_equipment_downtime。
--   【开着的一段不借更正关上,关了的一段不借更正重新打开】开着的那一段只能传空的结束时刻(给了就 DOWNTIME_CORRECT_CANNOT_CLOSE ——
--   关上它走 close_equipment_downtime);关了的那一段必须给结束时刻(DOWNTIME_END_REQUIRED)。
--   【原因代号必填】(Q3)—— 本刀之前那一行原因为空;谁更正它,谁就要给它一个原因(表上的 guard_downtime_cause 同一条)。
--   按名拒:DOWNTIME_NOT_FOUND · DOWNTIME_VOIDED · DOWNTIME_START_REQUIRED · DOWNTIME_END_BEFORE_START · 原因(downtime_cause_check)·
--   DOWNTIME_REASON_REQUIRED · DOWNTIME_NOTHING_CHANGED(什么都没改的一次"更正"不写任何东西,也不说成功)。
--   未来的时刻与重叠由 guard_downtime_period 按名拒。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.correct_equipment_downtime(p_downtime_id uuid, p_started_at timestamp with time zone, p_ended_at timestamp with time zone, p_cause_code text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d equipment_downtime%ROWTYPE;
    v_s text;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_d FROM equipment_downtime WHERE id = p_downtime_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOWNTIME_NOT_FOUND|%', COALESCE(p_downtime_id::text, '?');
    END IF;
    v_s := to_char(v_d.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    IF v_d.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_VOIDED|%', v_s;
    END IF;
    IF p_started_at IS NULL THEN
        RAISE EXCEPTION 'DOWNTIME_START_REQUIRED';
    END IF;
    IF v_d.ended_at IS NULL AND p_ended_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_CORRECT_CANNOT_CLOSE|%', v_s;
    END IF;
    IF v_d.ended_at IS NOT NULL AND p_ended_at IS NULL THEN
        RAISE EXCEPTION 'DOWNTIME_END_REQUIRED';
    END IF;
    IF p_ended_at IS NOT NULL AND p_ended_at < p_started_at THEN
        RAISE EXCEPTION 'DOWNTIME_END_BEFORE_START|%', to_char(p_started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    PERFORM downtime_cause_check(p_cause_code);
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DOWNTIME_REASON_REQUIRED';
    END IF;
    IF p_started_at = v_d.started_at AND p_ended_at IS NOT DISTINCT FROM v_d.ended_at
       AND p_cause_code IS NOT DISTINCT FROM v_d.cause_code AND btrim(p_reason) = v_d.reason THEN
        RAISE EXCEPTION 'DOWNTIME_NOTHING_CHANGED|%', v_s;
    END IF;
    UPDATE equipment_downtime
       SET started_at = p_started_at, ended_at = p_ended_at, cause_code = p_cause_code, reason = btrim(p_reason),
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_downtime_id;
    RETURN jsonb_build_object('downtime_id', p_downtime_id, 'equipment_id', v_d.equipment_id, 'corrected', true);
END;
$function$;
