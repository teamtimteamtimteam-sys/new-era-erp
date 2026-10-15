-- db/functions/submit_coa_void_request.sql
-- MES-6b-2(2026-10-15,MES-0 Q89 · MES-6b Step 0 Q20 · Q32,Tim):提一张申请 —— 作废一张已签发的分析证书。CFO 批准才生效
--   (warehouse_requests 的 coa_void,二级,不分档;提单人永远不能批)。门 action.issue_coa(cco · admin);其余全在
--   warehouse_request_submit_internal。【这是作废一张分析证书唯一的路】—— 没有一步作废的函数。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.submit_coa_void_request(p_coa_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.issue_coa');
    RETURN warehouse_request_submit_internal('coa_void', p_coa_id, p_reason);
END;
$function$
