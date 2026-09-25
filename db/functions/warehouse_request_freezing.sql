-- db/functions/warehouse_request_freezing.sql
-- APR-7(2026-09-25,grilling Q3):此刻冻结着这一批的那一张在等的仓库申请(id 与 label);没有 → 零行。
--   · 进料批:它自己是一张在等的注销申请的主体;
--   · 产出批:它自己是一张在等的注销申请的主体,或者它是一张在等回滚的加工单的产出。
-- 回滚的投料【不】冻结流水(还原是按消耗量加回去的,投料在等待中再被用掉不影响它);投料批不许被删,
-- 由 warehouse_request_conflict 管。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_freezing(p_inbound_batch_id uuid, p_output_batch_id uuid)
 RETURNS TABLE(request_id uuid, label text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT r.id, r.label FROM warehouse_requests r
     WHERE r.status = 'submitted' AND p_inbound_batch_id IS NOT NULL
       AND r.kind = 'write_off_inbound' AND r.inbound_batch_id = p_inbound_batch_id
    UNION ALL
    SELECT r.id, r.label FROM warehouse_requests r
     WHERE r.status = 'submitted' AND p_output_batch_id IS NOT NULL
       AND r.kind = 'write_off_output' AND r.output_batch_id = p_output_batch_id
    UNION ALL
    SELECT r.id, r.label FROM warehouse_requests r
      JOIN processing_outputs po ON po.run_id = r.run_id
     WHERE r.status = 'submitted' AND p_output_batch_id IS NOT NULL
       AND r.kind = 'rollback' AND po.output_batch_id = p_output_batch_id
$function$;
