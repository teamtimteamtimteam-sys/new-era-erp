-- db/functions/rollback_processing_run.sql
-- APR-7(2026-09-25):旧的一步回滚【一张都不回滚】—— 按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST|rollback|单号。
-- 回滚走 submit_rollback_request,CFO 批准才生效(Tim 的矩阵:仓库提,CFO 批每一张)。
-- 函数体搬进了 rollback_processing_run_internal;名字留着,是为了让旧屏幕与任何旧调用者得到一句按名的拒绝,
-- 而不是"函数不存在"。
-- 码先问(action.processing_rollback):没有它的人得到的仍是 PERMISSION_DENIED,与之前一样。
-- NOTE: rewritten by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.processing_rollback');
    RAISE EXCEPTION 'WAREHOUSE_NEEDS_APPROVED_REQUEST|rollback|%',
        COALESCE((SELECT code FROM processing_runs WHERE id = p_run_id), '?');
END;
$function$;
