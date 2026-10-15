-- db/functions/close_equipment_downtime.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q6,Tim):【机器回来了】—— 把开着的那一段停机关上。门 module.processing.edit。
--   按名拒:找不到(DOWNTIME_NOT_FOUND|<id>)· 已作废(DOWNTIME_VOIDED|<开始> —— 作废的那一段没有发生过,不能被"关上")·
--   已经关了(DOWNTIME_ALREADY_CLOSED|<开始>)· 没有结束时刻(DOWNTIME_END_REQUIRED)· 结束早于开始(DOWNTIME_END_BEFORE_START|<开始> ——
--   此前是约束名 equipment_downtime_period_order,现在先按名拒,约束留着做第二道)。结束在未来、与别的一段重叠由 guard_downtime_period 拒。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.close_equipment_downtime(p_downtime_id uuid, p_ended_at timestamp with time zone)
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
    IF v_d.ended_at IS NOT NULL THEN
        RAISE EXCEPTION 'DOWNTIME_ALREADY_CLOSED|%', v_s;
    END IF;
    IF p_ended_at IS NULL THEN
        RAISE EXCEPTION 'DOWNTIME_END_REQUIRED';
    END IF;
    IF p_ended_at < v_d.started_at THEN
        RAISE EXCEPTION 'DOWNTIME_END_BEFORE_START|%', v_s;
    END IF;
    UPDATE equipment_downtime SET ended_at = p_ended_at, updated_at = now(), updated_by = auth.uid() WHERE id = p_downtime_id;
    RETURN jsonb_build_object('downtime_id', p_downtime_id, 'equipment_id', v_d.equipment_id, 'open', false);
END;
$function$;
