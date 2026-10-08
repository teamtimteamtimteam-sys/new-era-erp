-- db/functions/meter_reading_internal.sql
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q20,Tim):【一条电表读数的判据与落库】—— 记与更正共用这一份。内层:不是 DEFINER,authenticated 调不到。
--   ① 那台设备必须是一台没停用的电表(METER_READING_DEVICE_NOT_METER);② 时刻不许在将来(METER_READING_IN_FUTURE),
--   读数不许为负(METER_READING_VALUE_INVALID);③ 同一台表同一刻已经有一条当前读数 → METER_READING_TIME_TAKEN;
--   ④ 比它【前面】那一条当前读数小 → METER_READING_BELOW_PREVIOUS|新|前,除非这一条标成寄存器清零(理由必填:METER_RESET_REASON_REQUIRED);
--   ⑤ 比它【后面】那一条当前读数大,而后面那一条不是寄存器清零 → METER_READING_ABOVE_NEXT|新|后(一条补记的旧读数不许把后面那一段变成负的)。
--   "当前" = 没被更正、没被撤回;查邻居时不算正在被更正的那一条(p_corrects_id)。撤回那一行不查(它让那一刻空出来)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE OR REPLACE FUNCTION public.meter_reading_internal(p_device_id uuid, p_read_at timestamp with time zone, p_register_kwh numeric, p_register_reset boolean, p_reset_reason text, p_notes text, p_withdraw boolean, p_corrects_id bigint, p_correction_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_dev    devices%ROWTYPE;
    v_reset  boolean := COALESCE(p_register_reset, false);
    v_reason text := NULLIF(btrim(COALESCE(p_reset_reason, '')), '');
    v_prev   meter_readings%ROWTYPE;
    v_next   meter_readings%ROWTYPE;
    v_id     bigint;
BEGIN
    SELECT * INTO v_dev FROM devices WHERE id = p_device_id;
    IF NOT FOUND OR v_dev.kind <> 'meter' OR v_dev.retired_at IS NOT NULL THEN
        RAISE EXCEPTION 'METER_READING_DEVICE_NOT_METER|%', COALESCE(v_dev.code, COALESCE(p_device_id::text, '?'));
    END IF;

    IF NOT COALESCE(p_withdraw, false) THEN
        IF p_read_at IS NULL THEN
            RAISE EXCEPTION 'METER_READING_TIME_REQUIRED';
        END IF;
        IF p_read_at > now() THEN
            RAISE EXCEPTION 'METER_READING_IN_FUTURE|%', p_read_at;
        END IF;
        IF p_register_kwh IS NULL OR p_register_kwh < 0 THEN
            RAISE EXCEPTION 'METER_READING_VALUE_INVALID';
        END IF;
        IF v_reset AND v_reason IS NULL THEN
            RAISE EXCEPTION 'METER_RESET_REASON_REQUIRED';
        END IF;
        IF EXISTS (SELECT 1 FROM meter_readings r
                    WHERE r.device_id = p_device_id AND r.read_at = p_read_at AND NOT r.withdrawn
                      AND r.id IS DISTINCT FROM p_corrects_id
                      AND NOT EXISTS (SELECT 1 FROM meter_readings x WHERE x.corrects_id = r.id)) THEN
            RAISE EXCEPTION 'METER_READING_TIME_TAKEN|%|%', v_dev.code, p_read_at;
        END IF;
        SELECT * INTO v_prev FROM meter_readings r
         WHERE r.device_id = p_device_id AND r.read_at < p_read_at AND NOT r.withdrawn
           AND r.id IS DISTINCT FROM p_corrects_id
           AND NOT EXISTS (SELECT 1 FROM meter_readings x WHERE x.corrects_id = r.id)
         ORDER BY r.read_at DESC, r.id DESC LIMIT 1;
        IF FOUND AND p_register_kwh < v_prev.register_kwh AND NOT v_reset THEN
            RAISE EXCEPTION 'METER_READING_BELOW_PREVIOUS|%|%', p_register_kwh, v_prev.register_kwh;
        END IF;
        SELECT * INTO v_next FROM meter_readings r
         WHERE r.device_id = p_device_id AND r.read_at > p_read_at AND NOT r.withdrawn
           AND r.id IS DISTINCT FROM p_corrects_id
           AND NOT EXISTS (SELECT 1 FROM meter_readings x WHERE x.corrects_id = r.id)
         ORDER BY r.read_at, r.id LIMIT 1;
        IF FOUND AND p_register_kwh > v_next.register_kwh AND NOT v_next.is_register_reset THEN
            RAISE EXCEPTION 'METER_READING_ABOVE_NEXT|%|%', p_register_kwh, v_next.register_kwh;
        END IF;
    END IF;

    INSERT INTO meter_readings (device_id, read_at, register_kwh, is_register_reset, reset_reason, withdrawn, source, notes,
                                corrects_id, correction_reason)
    VALUES (p_device_id, p_read_at, p_register_kwh, v_reset, CASE WHEN v_reset THEN v_reason END, COALESCE(p_withdraw, false),
            'manual', NULLIF(btrim(COALESCE(p_notes, '')), ''), p_corrects_id, p_correction_reason)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
