-- db/functions/set_batch_module_count.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q4,Tim):【在批次页上补或改一批的模组数】—— 进料批与产出批共用这一扇门。
--   p_kind:'inbound' | 'output'(BATCH_KIND_UNKNOWN)。码:批次那个模块的编辑码,或 action.processing_commit(放电站台的操作员);
--   都没有 → PERMISSION_DENIED|<模块编辑码>。p_count 为空 = 清掉;≤ 0 → MODULE_COUNT_INVALID|<值>。批次不在或已注销 → BATCH_NOT_FOUND。
--   适用性、下限与锁由表上的 guard_batch_module_count 判(同一份判据,直连 SQL 也过它)—— 这里一个字都不重复。
--   与原值相同 → 什么都不写。改了之后照规则重判一次核实(数改小可能刚好凑满;discharge_verify_batch)。返回批号。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.set_batch_module_count(p_kind text, p_batch_id uuid, p_count integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch   text;
    v_current integer;
BEGIN
    IF p_kind = 'inbound' THEN
        IF NOT has_any_permission(ARRAY['module.inbound.edit', 'action.processing_commit']) THEN
            RAISE EXCEPTION 'PERMISSION_DENIED|module.inbound.edit';
        END IF;
    ELSIF p_kind = 'output' THEN
        IF NOT has_any_permission(ARRAY['module.output.edit', 'action.processing_commit']) THEN
            RAISE EXCEPTION 'PERMISSION_DENIED|module.output.edit';
        END IF;
    ELSE
        RAISE EXCEPTION 'BATCH_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;
    IF p_count IS NOT NULL AND p_count <= 0 THEN
        RAISE EXCEPTION 'MODULE_COUNT_INVALID|%', p_count;
    END IF;

    IF p_kind = 'inbound' THEN
        SELECT b.code, b.module_count INTO v_batch, v_current
          FROM inbound_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL FOR UPDATE;
    ELSE
        SELECT b.code, b.module_count INTO v_batch, v_current
          FROM output_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL FOR UPDATE;
    END IF;
    IF v_batch IS NULL THEN
        RAISE EXCEPTION 'BATCH_NOT_FOUND|%', p_batch_id;
    END IF;
    IF v_current IS NOT DISTINCT FROM p_count THEN
        RETURN v_batch;
    END IF;

    IF p_kind = 'inbound' THEN
        UPDATE inbound_batches SET module_count = p_count, updated_by = auth.uid(), updated_at = now() WHERE id = p_batch_id;
    ELSE
        UPDATE output_batches SET module_count = p_count, updated_by = auth.uid(), updated_at = now() WHERE id = p_batch_id;
    END IF;
    PERFORM discharge_verify_batch(p_kind, p_batch_id,
        (SELECT s.latest_run_id FROM discharge_batch_status_all s WHERE s.batch_id = p_batch_id),
        'module count set to ' || COALESCE(p_count::text, 'none'));
    RETURN v_batch;
END;
$function$
