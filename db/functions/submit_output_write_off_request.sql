-- db/functions/submit_output_write_off_request.sql
-- APR-7(2026-09-25):仓库提一张申请 —— 注销一张还有料的产出批。CFO 批准才生效(Tim 的矩阵,不分档)。
-- 门 action.batch_write_off(ROLE-1 Batch 3b 的持有人:warehouse · admin);其余全在 warehouse_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_output_write_off_request(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.batch_write_off');
    RETURN warehouse_request_submit_internal('write_off_output', p_batch_id, p_reason);
END;
$function$;
