-- db/functions/warehouse_request_conflict.sql
-- APR-7(2026-09-25,grilling Q3):与 (p_kind, p_subject) 碰到同一样东西的、在等的那一张仓库申请的 label;
-- 没有 → NULL。提交时按名拒 WAREHOUSE_REQUEST_OPEN,一步删空批的那扇门也问它。
-- 【为什么要跨种类】一张在等的证书作废申请,遇上同一批货的注销或回滚被批准 —— 那一刻证书被自动作废,
-- 作废申请就再也批不出来,挂在那里挡住审批关闭。所以不让它们同时存在。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_conflict(p_kind text, p_subject uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT r.label
      FROM warehouse_requests r
     WHERE r.status = 'submitted'
       AND EXISTS (
           SELECT 1
             FROM warehouse_request_touches(r.kind, COALESCE(r.inbound_batch_id, r.output_batch_id, r.run_id, r.cod_id)) a
             JOIN warehouse_request_touches(p_kind, p_subject) b ON b.t = a.t AND b.id = a.id)
     ORDER BY r.created_at
     LIMIT 1
$function$;
