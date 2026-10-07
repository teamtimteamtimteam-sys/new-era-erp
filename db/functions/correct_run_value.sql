-- db/functions/correct_run_value.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q29,Tim):【更正一炉的一个值】—— 不改原行,落一条新的指回它(newest wins)。
--   持 action.processing_aftercare。理由必填;只能更正链的末端;p_value 为 null = 撤回这个值。加工单必须已提交、没回滚。
--   判据在 record_run_value_internal。返回新行 id。之后结平的水位线被越过 → 那一炉回到"没结平"(Q19)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.correct_run_value(p_value_id bigint, p_value jsonb, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run processing_runs%ROWTYPE;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT r.* INTO v_run FROM processing_runs r JOIN processing_run_values v ON v.run_id = r.id
     WHERE v.id = p_value_id FOR UPDATE OF r;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_VALUE_NOT_FOUND|%', p_value_id;
    END IF;
    IF v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.code;
    END IF;
    RETURN record_run_value_internal(v_run.id, NULL, p_value, 'manual', p_value_id, p_reason);
END;
$function$
