-- db/functions/set_batch_cell_construction.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-4b Step 0 Q4 · Q7,Tim):【在批次页上补或改电芯结构】—— 进料批与产出批共用这一扇门。
--   p_kind:'inbound' | 'output'(BATCH_KIND_UNKNOWN)。码:批次那个模块的编辑码,或 action.processing_commit(站台的操作员 ——
--   他在投料之前最先看见是卷绕还是叠片);都没有 → PERMISSION_DENIED|<模块编辑码>。
--   p_code 为空 = 清掉(回到"没记")。不认识或已停用的结构 → CELL_CONSTRUCTION_UNKNOWN|<码>。批次不在或已注销 → BATCH_NOT_FOUND。
--   适用性与锁由表上的 guard_batch_cell_construction 判(同一份判据,直连 SQL 也过它)—— 这里一个字都不重复。
--   与原值相同 → 什么都不写(不落一条空的变更记录)。返回批号。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.set_batch_cell_construction(p_kind text, p_batch_id uuid, p_code text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code    text := NULLIF(btrim(COALESCE(p_code, '')), '');
    v_batch   text;
    v_current text;
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

    IF v_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM cell_constructions c WHERE c.code = v_code AND c.is_active) THEN
        RAISE EXCEPTION 'CELL_CONSTRUCTION_UNKNOWN|%', v_code;
    END IF;

    IF p_kind = 'inbound' THEN
        SELECT b.code, b.cell_construction_code INTO v_batch, v_current
          FROM inbound_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL FOR UPDATE;
    ELSE
        SELECT b.code, b.cell_construction_code INTO v_batch, v_current
          FROM output_batches b WHERE b.id = p_batch_id AND b.deleted_at IS NULL FOR UPDATE;
    END IF;
    IF v_batch IS NULL THEN
        RAISE EXCEPTION 'BATCH_NOT_FOUND|%', p_batch_id;
    END IF;
    IF v_current IS NOT DISTINCT FROM v_code THEN
        RETURN v_batch;
    END IF;

    IF p_kind = 'inbound' THEN
        UPDATE inbound_batches SET cell_construction_code = v_code, updated_by = auth.uid(), updated_at = now() WHERE id = p_batch_id;
    ELSE
        UPDATE output_batches SET cell_construction_code = v_code, updated_by = auth.uid(), updated_at = now() WHERE id = p_batch_id;
    END IF;
    RETURN v_batch;
END;
$function$