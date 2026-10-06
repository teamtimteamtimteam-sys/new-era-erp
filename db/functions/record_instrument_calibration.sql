-- db/functions/record_instrument_calibration.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q31;MES-2 Step 0 Q23 · Q24,Tim):【记一次校准】。持 action.manage_devices(cto · admin)。
--   仪器要在、没停用(DEVICE_NOT_FOUND · DEVICE_RETIRED|<编号>),而且是一台量东西的仪器 —— 秤、地磅、电表、在线仪表
--   (CALIBRATION_KIND_INVALID|<种类>,Q23)。校准日与证书有效期都必填(CALIBRATION_DATE_REQUIRED);有效期不早于校准日
--   (CALIBRATION_VALID_UNTIL_BEFORE_CALIBRATED);校准日不在将来(CALIBRATION_IN_FUTURE —— 补录过去的证书可以,
--   它对它覆盖的那段时间算数,Q25);结论 passed / failed(CALIBRATION_RESULT_INVALID)。返回那一行的 id。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.record_instrument_calibration(p_device_id uuid, p_calibrated_on date, p_valid_until date, p_result text, p_certificate_no text DEFAULT NULL::text, p_calibrating_body text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_dev devices%ROWTYPE;
    v_id  bigint;
BEGIN
    PERFORM require_permission('action.manage_devices');
    SELECT * INTO v_dev FROM devices WHERE id = p_device_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DEVICE_NOT_FOUND';
    END IF;
    IF v_dev.retired_at IS NOT NULL THEN
        RAISE EXCEPTION 'DEVICE_RETIRED|%', v_dev.code;
    END IF;
    IF v_dev.kind NOT IN ('scale', 'weighbridge', 'meter', 'inline_instrument') THEN
        RAISE EXCEPTION 'CALIBRATION_KIND_INVALID|%', v_dev.kind;
    END IF;
    IF p_calibrated_on IS NULL OR p_valid_until IS NULL THEN
        RAISE EXCEPTION 'CALIBRATION_DATE_REQUIRED';
    END IF;
    IF p_valid_until < p_calibrated_on THEN
        RAISE EXCEPTION 'CALIBRATION_VALID_UNTIL_BEFORE_CALIBRATED';
    END IF;
    IF p_calibrated_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'CALIBRATION_IN_FUTURE';
    END IF;
    IF p_result IS NULL OR p_result NOT IN ('passed', 'failed') THEN
        RAISE EXCEPTION 'CALIBRATION_RESULT_INVALID|%', COALESCE(p_result, '?');
    END IF;
    INSERT INTO instrument_calibrations (device_id, calibrated_on, valid_until, result, certificate_no, calibrating_body, notes, recorded_by)
    VALUES (p_device_id, p_calibrated_on, p_valid_until, p_result, NULLIF(btrim(COALESCE(p_certificate_no, '')), ''),
            NULLIF(btrim(COALESCE(p_calibrating_body, '')), ''), NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid())
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;
