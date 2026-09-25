-- db/functions/submit_rollback_request.sql
-- APR-7(2026-09-25):仓库提一张申请 —— 回滚一张加工单。CFO 批准才生效(Tim 的矩阵,不分档)。
-- 门 action.processing_rollback(ROLE-1 Batch 3b 的持有人:warehouse · admin);其余全在 warehouse_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_rollback_request(p_run_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.processing_rollback');
    RETURN warehouse_request_submit_internal('rollback', p_run_id, p_reason);
END;
$function$;
