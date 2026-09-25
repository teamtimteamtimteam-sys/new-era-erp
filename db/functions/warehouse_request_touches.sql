-- db/functions/warehouse_request_touches.sql
-- APR-7(2026-09-25,grilling Q3):一张仓库申请【碰到】哪些东西 —— 一份判据,三个读它的人:
--   提交时的"同一时刻只挂一张"(warehouse_request_conflict)· 一步删空批的那扇门 · 屏幕上"为什么灰掉"。
--   write_off_inbound  那一批('in')+ 它的活证书('cod')
--   write_off_output   那一批('out')
--   rollback           那张单('run')+ 它的产出批('out')+ 它的投料 —— 进料批('in')与产出批投料('out')
--                      + 投料进料批上的活证书('cod')
--   cod_void           那张证书('cod')+ 它的进料批('in')
-- 【现读,不冻结】碰到什么是此刻的事实;冻结(guard_warehouse_request_freeze)保证它在等的时候不变。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_touches(p_kind text, p_subject uuid)
 RETURNS TABLE(t text, id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT 'in'::text, p_subject WHERE p_kind = 'write_off_inbound'
    UNION
    SELECT 'cod', c.id FROM certificates_of_destruction c
     WHERE p_kind = 'write_off_inbound' AND c.inbound_batch_id = p_subject AND c.status <> 'void'
    UNION
    SELECT 'out', p_subject WHERE p_kind = 'write_off_output'
    UNION
    SELECT 'run', p_subject WHERE p_kind = 'rollback'
    UNION
    SELECT 'out', po.output_batch_id FROM processing_outputs po
     WHERE p_kind = 'rollback' AND po.run_id = p_subject
    UNION
    SELECT CASE WHEN pi.inbound_batch_id IS NOT NULL THEN 'in' ELSE 'out' END,
           COALESCE(pi.inbound_batch_id, pi.output_batch_id)
      FROM processing_inputs pi
     WHERE p_kind = 'rollback' AND pi.run_id = p_subject
    UNION
    SELECT 'cod', c.id FROM processing_inputs pi
      JOIN certificates_of_destruction c ON c.inbound_batch_id = pi.inbound_batch_id AND c.status <> 'void'
     WHERE p_kind = 'rollback' AND pi.run_id = p_subject
    UNION
    SELECT 'cod', p_subject WHERE p_kind = 'cod_void'
    UNION
    SELECT 'in', c.inbound_batch_id FROM certificates_of_destruction c
     WHERE p_kind = 'cod_void' AND c.id = p_subject
$function$;

COMMENT ON FUNCTION public.warehouse_request_touches(text, uuid) IS
'APR-7(grilling Q3):一张仓库申请碰到的批次(in / out)、加工单(run)与证书(cod)。一个批次、它的证书、消耗它的加工单同一时刻只许挂一张在等的申请 —— 那条规矩就是"两张申请的这个集合不许相交"。';
