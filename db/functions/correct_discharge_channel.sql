-- db/functions/correct_discharge_channel.sql
-- MES-5a-1(2026-10-08,MES-5a Step 0 Q9,Tim):【更正或撤回一条通道分配】—— 新行指回原行(corrects_id 唯一)+ 理由必填;只追加。
--   p_withdraw 为真 = 撤回(这个通道空出来;通道号与模组照抄原行);否则用这一次给的通道号与模组重写(同一套判据)。
--   码:action.processing_aftercare。拒:DISCHARGE_ASSIGNMENT_NOT_FOUND|<id> · DISCHARGE_ASSIGNMENT_SUPERSEDED|<id> ·
--   DISCHARGE_CORRECTION_REASON_REQUIRED · DISCHARGE_CORRECTION_SAME_VALUE,以及 assign_discharge_channel 那几条。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.correct_discharge_channel(p_id bigint, p_channel_no integer, p_module_ref text, p_withdraw boolean, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig discharge_channel_assignments%ROWTYPE;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_orig FROM discharge_channel_assignments WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DISCHARGE_ASSIGNMENT_NOT_FOUND|%', p_id;
    END IF;
    IF EXISTS (SELECT 1 FROM discharge_channel_assignments x WHERE x.corrects_id = p_id) THEN
        RAISE EXCEPTION 'DISCHARGE_ASSIGNMENT_SUPERSEDED|%', p_id;
    END IF;
    IF v_orig.withdrawn THEN
        RAISE EXCEPTION 'DISCHARGE_ASSIGNMENT_SUPERSEDED|%', p_id;
    END IF;
    IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
        RAISE EXCEPTION 'DISCHARGE_CORRECTION_REASON_REQUIRED';
    END IF;
    IF NOT COALESCE(p_withdraw, false) AND p_channel_no IS NOT DISTINCT FROM v_orig.channel_no
       AND NULLIF(btrim(COALESCE(p_module_ref, '')), '') IS NOT DISTINCT FROM v_orig.module_ref THEN
        RAISE EXCEPTION 'DISCHARGE_CORRECTION_SAME_VALUE';
    END IF;
    RETURN discharge_channel_internal(v_orig.run_id,
        CASE WHEN v_orig.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END,
        COALESCE(v_orig.inbound_batch_id, v_orig.output_batch_id),
        CASE WHEN COALESCE(p_withdraw, false) THEN v_orig.channel_no ELSE p_channel_no END,
        CASE WHEN COALESCE(p_withdraw, false) THEN v_orig.module_ref ELSE p_module_ref END,
        COALESCE(p_withdraw, false), p_id, p_reason);
END;
$function$
