-- db/functions/discharge_channel_internal.sql
-- MES-5a-1(2026-10-08,MES-5a Step 0 Q9,Tim):【一条通道分配的判据与落库】—— 记与更正共用这一份。内层:不是 DEFINER,authenticated 调不到。
--   "当前" = 没被更正、没被撤回。查重时不算正在被更正的那一条(p_corrects_id)。撤回那一行不查重(它让通道空出来)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.discharge_channel_internal(p_run_id uuid, p_kind text, p_batch_id uuid, p_channel_no integer, p_module_ref text, p_withdraw boolean, p_corrects_id bigint, p_correction_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run     processing_runs%ROWTYPE;
    v_by_unit boolean;
    v_ref     text := NULLIF(btrim(COALESCE(p_module_ref, '')), '');
    v_other   text;
    v_id      bigint;
BEGIN
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, COALESCE(p_run_id::text, '?'));
    END IF;
    SELECT ot.verifies_by_unit INTO v_by_unit FROM operation_types ot WHERE ot.code = v_run.operation_type_code;
    IF v_by_unit IS NOT TRUE THEN
        RAISE EXCEPTION 'DISCHARGE_RUN_NOT_BY_UNIT|%|%', v_run.code, COALESCE(v_run.operation_type_code, '?');
    END IF;
    IF p_kind NOT IN ('inbound', 'output') OR p_kind IS NULL THEN
        RAISE EXCEPTION 'BATCH_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.run_id = p_run_id
                     AND ((p_kind = 'inbound' AND pi.inbound_batch_id = p_batch_id) OR (p_kind = 'output' AND pi.output_batch_id = p_batch_id))) THEN
        RAISE EXCEPTION 'DISCHARGE_BATCH_NOT_INPUT|%', v_run.code;
    END IF;
    IF p_channel_no IS NULL OR p_channel_no <= 0 THEN
        RAISE EXCEPTION 'DISCHARGE_VALUE_INVALID|channel_no';
    END IF;
    IF v_ref IS NULL OR length(v_ref) > 60 THEN
        RAISE EXCEPTION 'DISCHARGE_MODULE_REF_REQUIRED';
    END IF;

    IF NOT COALESCE(p_withdraw, false) THEN
        SELECT a.module_ref INTO v_other FROM discharge_channel_assignments a
         WHERE a.run_id = p_run_id AND a.channel_no = p_channel_no AND NOT a.withdrawn
           AND a.id IS DISTINCT FROM p_corrects_id
           AND NOT EXISTS (SELECT 1 FROM discharge_channel_assignments x WHERE x.corrects_id = a.id)
         LIMIT 1;
        IF v_other IS NOT NULL THEN
            RAISE EXCEPTION 'DISCHARGE_CHANNEL_TAKEN|%|%', p_channel_no, v_other;
        END IF;
        SELECT a.channel_no::text INTO v_other FROM discharge_channel_assignments a
         WHERE a.run_id = p_run_id AND COALESCE(a.inbound_batch_id, a.output_batch_id) = p_batch_id AND a.module_ref = v_ref
           AND NOT a.withdrawn AND a.id IS DISTINCT FROM p_corrects_id
           AND NOT EXISTS (SELECT 1 FROM discharge_channel_assignments x WHERE x.corrects_id = a.id)
         LIMIT 1;
        IF v_other IS NOT NULL THEN
            RAISE EXCEPTION 'DISCHARGE_MODULE_ALREADY_ON_CHANNEL|%|%', v_ref, v_other;
        END IF;
    END IF;

    INSERT INTO discharge_channel_assignments (run_id, inbound_batch_id, output_batch_id, channel_no, module_ref, withdrawn,
                                               corrects_id, correction_reason)
    VALUES (p_run_id, CASE WHEN p_kind = 'inbound' THEN p_batch_id END, CASE WHEN p_kind = 'output' THEN p_batch_id END,
            p_channel_no, v_ref, COALESCE(p_withdraw, false), p_corrects_id, NULLIF(btrim(COALESCE(p_correction_reason, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
