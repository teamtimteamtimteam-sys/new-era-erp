-- db/functions/correct_run_header.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q30,Tim):【更正一张加工单表头的一个字段】—— 留一行更正,再改表头。
--   只有六个字段:started_at · ended_at · shift_code · equipment_id · recipe_version_id · notes;别的 → RUN_HEADER_FIELD_NOT_CORRECTABLE|<字段>
--   (加工日、数量、工序、工单改了就是另一炉:回滚申请 + 新单带 corrects_run_id)。
--   码:action.processing_commit —— 提交那一炉的人(warehouse · admin)。加工单必须已提交、没回滚(RUN_NOT_COMMITTED)。理由必填;
--   新值与旧值相同按名拒(RUN_HEADER_CORRECTION_SAME_VALUE)。
--   【MES-4a 之前的单】(开始时刻为空)一个字段都不改 → RUN_HEADER_PREDATES_RECORD|<单>:给它补时刻、班次、机器、配方就是回填(Q21 不回填);
--   连备注也不改 —— 那些单都没有工序,而 processing_runs_operation_type_required 那条 NOT VALID 的 CHECK 对【每一次 UPDATE】照样检查,
--   改任何一列都会撞上它(登记在 docs/known-issues.md 的 MES4A-NOT-VALID-CHECK-BLOCKS-OLD-RUN-UPDATES)。旧单原样留着。
--   新值过与提交时【同一份】判据:时刻与班次 → assert_run_header(按改后的整组再问一遍);机器 → assert_run_equipment;
--   配方版本 → 属于这道工序、配方启用着(或清空)。表头经属主路径改(updated_by / updated_at 跟着动),原值留在 processing_run_corrections
--   与变更记录里。返回更正行的 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.correct_run_header(p_run_id uuid, p_field text, p_value text, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run   processing_runs%ROWTYPE;
    v_val   text := NULLIF(btrim(COALESCE(p_value, '')), '');
    v_old   text;
    v_ts    timestamptz;
    v_uuid  uuid;
    v_rc    record;
    v_id    bigint;
BEGIN
    PERFORM require_permission('action.processing_commit');
    IF p_field IS NULL OR p_field NOT IN ('started_at', 'ended_at', 'shift_code', 'equipment_id', 'recipe_version_id', 'notes') THEN
        RAISE EXCEPTION 'RUN_HEADER_FIELD_NOT_CORRECTABLE|%', COALESCE(p_field, '?')
          USING HINT = '能更正的只有开始、结束、班次、机器、配方版本与备注。加工日、数量、工序与工单改了就是另一炉:走回滚申请,再记一张新单指回它。';
    END IF;
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'RUN_HEADER_CORRECTION_REASON_REQUIRED';
    END IF;
    IF v_run.started_at IS NULL THEN
        RAISE EXCEPTION 'RUN_HEADER_PREDATES_RECORD|%', v_run.code
          USING HINT = '这张单记在 MES-4a 之前:表头不更正。给它补时刻、班次、机器或配方就是回填,而旧单不回填。';
    END IF;

    v_old := CASE p_field WHEN 'started_at' THEN v_run.started_at::text WHEN 'ended_at' THEN v_run.ended_at::text
                          WHEN 'shift_code' THEN v_run.shift_code WHEN 'equipment_id' THEN v_run.equipment_id::text
                          WHEN 'recipe_version_id' THEN v_run.recipe_version_id::text ELSE v_run.notes END;

    IF p_field IN ('started_at', 'ended_at') THEN
        IF v_val IS NULL THEN
            RAISE EXCEPTION 'RUN_TIMES_REQUIRED|%', CASE p_field WHEN 'started_at' THEN 'start' ELSE 'end' END;
        END IF;
        BEGIN
            v_ts := v_val::timestamptz;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'RUN_HEADER_VALUE_INVALID|%', p_field;
        END;
        IF v_ts IS NOT DISTINCT FROM (CASE p_field WHEN 'started_at' THEN v_run.started_at ELSE v_run.ended_at END) THEN
            RAISE EXCEPTION 'RUN_HEADER_CORRECTION_SAME_VALUE';
        END IF;
        PERFORM assert_run_header(v_run.process_date,
                                  CASE p_field WHEN 'started_at' THEN v_ts ELSE v_run.started_at END,
                                  CASE p_field WHEN 'ended_at' THEN v_ts ELSE v_run.ended_at END,
                                  v_run.shift_code);
        IF p_field = 'started_at' THEN
            UPDATE processing_runs SET started_at = v_ts, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
        ELSE
            UPDATE processing_runs SET ended_at = v_ts, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
        END IF;
        v_val := v_ts::text;
    ELSIF p_field = 'shift_code' THEN
        IF v_val IS NOT DISTINCT FROM v_run.shift_code THEN
            RAISE EXCEPTION 'RUN_HEADER_CORRECTION_SAME_VALUE';
        END IF;
        PERFORM assert_run_header(v_run.process_date, v_run.started_at, v_run.ended_at, v_val);
        UPDATE processing_runs SET shift_code = v_val, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
    ELSIF p_field = 'equipment_id' THEN
        BEGIN
            v_uuid := v_val::uuid;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'RUN_HEADER_VALUE_INVALID|%', p_field;
        END;
        IF v_uuid IS NOT DISTINCT FROM v_run.equipment_id THEN
            RAISE EXCEPTION 'RUN_HEADER_CORRECTION_SAME_VALUE';
        END IF;
        PERFORM assert_run_equipment(v_run.operation_type_code, v_uuid, v_run.process_date);
        UPDATE processing_runs SET equipment_id = v_uuid, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
    ELSIF p_field = 'recipe_version_id' THEN
        BEGIN
            v_uuid := v_val::uuid;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'RUN_HEADER_VALUE_INVALID|%', p_field;
        END;
        IF v_uuid IS NOT DISTINCT FROM v_run.recipe_version_id THEN
            RAISE EXCEPTION 'RUN_HEADER_CORRECTION_SAME_VALUE';
        END IF;
        IF v_uuid IS NOT NULL THEN
            SELECT rc.code, rc.operation_type_code, rc.is_active INTO v_rc
              FROM process_recipe_versions rv JOIN process_recipes rc ON rc.id = rv.recipe_id WHERE rv.id = v_uuid;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'RECIPE_VERSION_NOT_FOUND|%', v_uuid;
            END IF;
            IF v_rc.operation_type_code <> v_run.operation_type_code THEN
                RAISE EXCEPTION 'RECIPE_VERSION_NOT_FOR_OPERATION|%|%', v_rc.code, v_run.operation_type_code;
            END IF;
            IF NOT v_rc.is_active THEN
                RAISE EXCEPTION 'RECIPE_INACTIVE|%', v_rc.code;
            END IF;
        END IF;
        UPDATE processing_runs SET recipe_version_id = v_uuid, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
    ELSE
        IF v_val IS NOT DISTINCT FROM NULLIF(btrim(COALESCE(v_run.notes, '')), '') THEN
            RAISE EXCEPTION 'RUN_HEADER_CORRECTION_SAME_VALUE';
        END IF;
        UPDATE processing_runs SET notes = v_val, updated_by = auth.uid(), updated_at = now() WHERE id = p_run_id;
    END IF;

    INSERT INTO processing_run_corrections (run_id, field, old_value, new_value, reason)
    VALUES (p_run_id, p_field, v_old, v_val, btrim(p_reason))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
