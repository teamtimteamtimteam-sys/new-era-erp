-- db/functions/void_cod.sql
-- APR-7(2026-09-25):旧的一步作废【一张都不作废】—— 按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST|cod_void|证书号。
-- 作废走 submit_cod_void_request,CFO 批准才生效(Tim 的矩阵:仓库提,CFO 批每一张)。在等的时候,公开核验页
-- 照旧说"有效" —— 那是真的,还没有东西生效。
-- 作废本身仍是 void_cod_internal(字节档案与快照一个字不动)。
-- 码先问(action.issue_cod):没有它的人得到的仍是 PERMISSION_DENIED,与之前一样。
-- NOTE: rewritten by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.void_cod(p_cod_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.issue_cod');
    RAISE EXCEPTION 'WAREHOUSE_NEEDS_APPROVED_REQUEST|cod_void|%',
        COALESCE((SELECT COALESCE(code, id::text) FROM certificates_of_destruction WHERE id = p_cod_id), '?');
END;
$function$;
