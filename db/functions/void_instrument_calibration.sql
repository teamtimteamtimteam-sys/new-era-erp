-- db/functions/void_instrument_calibration.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q24,Tim):【作废一条记错了的校准记录】—— 理由必填(CALIBRATION_VOID_REASON_REQUIRED);
--   只作废一次(CALIBRATION_VOIDED|<id>)。作废的那一行从此不参与"在不在期内"的判断。持 action.manage_devices。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.void_instrument_calibration(p_id bigint, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_voided timestamptz;
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CALIBRATION_VOID_REASON_REQUIRED';
    END IF;
    SELECT voided_at INTO v_voided FROM instrument_calibrations WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CALIBRATION_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_voided IS NOT NULL THEN
        RAISE EXCEPTION 'CALIBRATION_VOIDED|%', p_id;
    END IF;
    UPDATE instrument_calibrations SET voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason) WHERE id = p_id;
END;
$function$;
