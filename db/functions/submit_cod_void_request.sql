-- db/functions/submit_cod_void_request.sql
-- APR-7(2026-09-25):仓库提一张申请 —— 作废一张已签发的销毁证书。CFO 批准才生效(Tim 的矩阵,不分档)。
-- 门 action.issue_cod(ROLE-1 Batch 3b 的持有人:warehouse · admin);其余全在 warehouse_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_cod_void_request(p_cod_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.issue_cod');
    RETURN warehouse_request_submit_internal('cod_void', p_cod_id, p_reason);
END;
$function$;
