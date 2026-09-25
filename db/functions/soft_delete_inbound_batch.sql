-- db/functions/soft_delete_inbound_batch.sql
-- APR-7(2026-09-25):注销进料批的那扇【一步】的门 —— 只剩空批(grilling Q1)。
--   还有料、或挂着已签发销毁证书的批次 → 按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_inbound|批号:
--   它们走 submit_inbound_write_off_request,CFO 批准才生效。
--   空批还要问一句:它有没有被一张在等的申请碰到(回滚的投料、证书作废)→ WAREHOUSE_REQUEST_OPEN。
--   其余原样交给 soft_delete_inbound_batch_internal(理由必填、定价申请、欠款、证书刷新都在那里)。
-- 门 action.batch_write_off(ROLE-1 Batch 3b)。
-- NOTE: rewritten by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.soft_delete_inbound_batch(p_batch_id uuid, p_reason text)
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
    SELECT code INTO v_code FROM inbound_batches WHERE id = p_batch_id AND deleted_at IS NULL;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF batch_write_off_needs_request(p_batch_id, NULL) THEN
        RAISE EXCEPTION 'WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_inbound|%', v_code;
    END IF;
    v_open := warehouse_request_conflict('write_off_inbound', p_batch_id);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;
    RETURN soft_delete_inbound_batch_internal(p_batch_id, p_reason, NULL);
END;
$function$;
