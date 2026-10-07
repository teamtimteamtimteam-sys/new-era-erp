-- db/functions/record_run_value.sql
-- MES-4a(2026-10-07,MES-0 Q43;MES-4a Step 0 Q11 · Q34,Tim):【提交之后,在加工单页上给一炉记一个值】。
--   持 action.processing_aftercare(记损耗与交接班的那个码 —— 提交之后的补记归它,Q34)。加工单必须已提交、没回滚(RUN_NOT_COMMITTED)。
--   判据全在 record_run_value_internal(字段属于这道工序、启用着、还没有当前值、按类型验、抄范围)。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_run_value(p_run_id uuid, p_field_code text, p_value jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run processing_runs%ROWTYPE;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    RETURN record_run_value_internal(p_run_id, p_field_code, p_value, 'manual', NULL, NULL);
END;
$function$
