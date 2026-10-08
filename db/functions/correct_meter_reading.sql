-- db/functions/correct_meter_reading.sql
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q20,Tim):【更正 / 撤回一条电表读数】—— 新的一行指回原行(corrects_id),理由必填;原行留着。
--   p_withdraw = true:撤回(这一条记在了错的表上,或根本不该有)—— 新行抄原行的时刻与读数、标 withdrawn,那一刻空出来。
--   否则:新的时刻 / 读数 / 是否寄存器清零(理由)照记数一样再判一遍(meter_reading_internal,查邻居时不算原行)。
--   只能更正当前的那一条(METER_READING_SUPERSEDED|id);什么都没改拒(METER_READING_CORRECTION_SAME_VALUE)。action.confirm_capture。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE OR REPLACE FUNCTION public.correct_meter_reading(p_reading_id bigint, p_reason text, p_read_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_register_kwh numeric DEFAULT NULL::numeric, p_register_reset boolean DEFAULT NULL::boolean, p_reset_reason text DEFAULT NULL::text, p_withdraw boolean DEFAULT false, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig   meter_readings%ROWTYPE;
    v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_at     timestamptz;
    v_kwh    numeric;
    v_reset  boolean;
    v_rr     text;
    v_id     bigint;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    SELECT * INTO v_orig FROM meter_readings WHERE id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'METER_READING_NOT_FOUND|%', COALESCE(p_reading_id::text, '?');
    END IF;
    IF v_orig.withdrawn OR EXISTS (SELECT 1 FROM meter_readings x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'METER_READING_SUPERSEDED|%', v_orig.id;
    END IF;
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'METER_CORRECTION_REASON_REQUIRED';
    END IF;

    IF COALESCE(p_withdraw, false) THEN
        v_id := meter_reading_internal(v_orig.device_id, v_orig.read_at, v_orig.register_kwh, v_orig.is_register_reset, v_orig.reset_reason,
                                       v_orig.notes, true, v_orig.id, v_reason);
        RETURN jsonb_build_object('id', v_id, 'withdrawn', true);
    END IF;

    v_at    := COALESCE(p_read_at, v_orig.read_at);
    v_kwh   := COALESCE(p_register_kwh, v_orig.register_kwh);
    v_reset := COALESCE(p_register_reset, v_orig.is_register_reset);
    v_rr    := CASE WHEN v_reset THEN COALESCE(NULLIF(btrim(COALESCE(p_reset_reason, '')), ''), v_orig.reset_reason) END;
    IF v_at = v_orig.read_at AND v_kwh = v_orig.register_kwh AND v_reset = v_orig.is_register_reset
       AND v_rr IS NOT DISTINCT FROM v_orig.reset_reason
       AND COALESCE(NULLIF(btrim(COALESCE(p_notes, '')), ''), v_orig.notes) IS NOT DISTINCT FROM v_orig.notes THEN
        RAISE EXCEPTION 'METER_READING_CORRECTION_SAME_VALUE';
    END IF;
    v_id := meter_reading_internal(v_orig.device_id, v_at, v_kwh, v_reset, v_rr, COALESCE(p_notes, v_orig.notes), false, v_orig.id, v_reason);
    RETURN jsonb_build_object('id', v_id, 'withdrawn', false);
END;
$function$
