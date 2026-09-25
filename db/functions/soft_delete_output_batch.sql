-- db/functions/soft_delete_output_batch.sql
-- APR-7(2026-09-25):注销产出批的那扇【一步】的门 —— 只剩空批(grilling Q1)。
--   还有料 → 按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_output|批号(走 submit_output_write_off_request)。
--   空批被一张在等的申请碰到(回滚的产出或投料)→ WAREHOUSE_REQUEST_OPEN。
--   其余原样交给 soft_delete_output_batch_internal。门 action.batch_write_off(ROLE-1 Batch 3b)。
-- NOTE: rewritten by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.soft_delete_output_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_open text;
BEGIN
    PERFORM require_permission('action.batch_write_off');
    SELECT code INTO v_code FROM output_batches WHERE id = p_batch_id AND deleted_at IS NULL;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF batch_write_off_needs_request(NULL, p_batch_id) THEN
        RAISE EXCEPTION 'WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_output|%', v_code;
    END IF;
    v_open := warehouse_request_conflict('write_off_output', p_batch_id);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;
    RETURN soft_delete_output_batch_internal(p_batch_id, p_reason, NULL);
END;
$function$;
