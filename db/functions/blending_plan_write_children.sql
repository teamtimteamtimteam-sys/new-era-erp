-- db/functions/blending_plan_write_children.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q20,Tim):【一份配料计划的判据与落库 —— 产出物料、目标品位、候选批次】
--   create_blending_plan 与 amend_blending_plan 共用这一段(一份判据,两个调用者 —— AGENTS.md 的预览规则同一条)。
--   ★ 内层:它【不查码】,也【不是】DEFINER(reverse_expense_internal 的同一个形状)—— 它只在两支查过 action.wo_create 的 DEFINER 函数里
--     以属主身份跑;EXECUTE 从 authenticated 收回(zzz_function_grants.sql)。
--   判的顺序就是人下一步该改什么的顺序:先产出物料,再合同,再目标,再批次。
--     ① 产出物料:存在、没删;形态【可售】(material_forms.may_be_sold,R5)—— 否则 BLEND_OUTPUT_NOT_SALEABLE|<物料>|<形态>|<中文>|<英文>;
--        形态是配料这道工序声明的产出形态 —— 否则 BLEND_OUTPUT_FORM_NOT_BLENDABLE|<物料>|<形态或空>。
--     ② 合同(可空):存在 —— 否则 BLEND_CONTRACT_NOT_FOUND。
--     ③ 目标:p_targets 为 NULL 且有合同 → 抄那份合同里【适用于这种物料】的每一条品位规格(物料为空的,或就是这种物料的;同一种金属
--        两条都有时取指名物料的那一条)。否则逐条:{grade_spec_id} → 抄那一条(必须属于这份合同 BLEND_TARGET_SPEC_NOT_FROM_CONTRACT、
--        适用于这种物料 BLEND_TARGET_SPEC_OTHER_MATERIAL),来源 contract;{metal, min_pct, max_pct} → 人敲的,来源 manual:
--        金属在字典里(METAL_INVALID)· 至少一个界(BLEND_TARGET_NEEDS_A_BOUND)· 0–100(BLEND_TARGET_PCT_INVALID)·
--        下界不高于上界(BLEND_TARGET_BOUNDS_ORDER)· 一种金属一行(BLEND_TARGET_DUPLICATE_METAL)。
--     ④ 批次:至少一行(BLEND_NO_LINES);每一行恰好一批(BLEND_LINE_ONE_BATCH)、存在且没删(INBOUND_NOT_FOUND / OUTPUT_NOT_FOUND)、
--        单位是 kg(BLEND_LINE_UNIT_NOT_KG)、物料形态是配料收的(BLEND_LINE_FORM_NOT_BLENDABLE|<批号>|<形态或空>)、
--        计划公斤数 > 0(BLEND_LINE_KG_INVALID|<批号>)、一批一行(BLEND_LINE_DUPLICATE_BATCH|<批号>)。
--        【不】拒计划的公斤数超过这一批此刻的余量 —— 计划可以是为将来排的;真投的时候引擎照旧按余量拒。
--   然后整份替换:删掉这份计划原有的目标与批次,写入新的(变更记录逐行记下删与插)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.blending_plan_write_children(p_plan_id uuid, p_output_material_id uuid, p_source_contract_id uuid, p_targets jsonb, p_lines jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_mat      record;
    v_el       jsonb;
    v_spec     contract_grade_specs%ROWTYPE;
    v_metal    text;
    v_min      numeric;
    v_max      numeric;
    v_metals   text[] := ARRAY[]::text[];
    v_ib       uuid;
    v_ob       uuid;
    v_kg       numeric;
    v_bcode    text;
    v_bunit    text;
    v_bform    text;
    v_batches  text[] := ARRAY[]::text[];
BEGIN
    -- ① 产出物料
    SELECT m.code, m.form_code, f.may_be_sold, f.name_zh, f.name_en INTO v_mat
      FROM materials m LEFT JOIN material_forms f ON f.code = m.form_code
     WHERE m.id = p_output_material_id AND m.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', COALESCE(p_output_material_id::text, '?');
    END IF;
    IF v_mat.form_code IS NOT NULL AND v_mat.may_be_sold IS FALSE THEN
        RAISE EXCEPTION 'BLEND_OUTPUT_NOT_SALEABLE|%|%|%|%', v_mat.code, v_mat.form_code, v_mat.name_zh, v_mat.name_en
          USING HINT = '配料混出来的那一批必须是可以卖的形态(R5)。这一种物料的形态在法律上不许出售,所以不能是一份配料计划的产出。';
    END IF;
    IF v_mat.form_code IS NULL OR NOT EXISTS (SELECT 1 FROM operation_type_output_forms o
                                               WHERE o.operation_type_code = 'blending' AND o.form_code = v_mat.form_code) THEN
        RAISE EXCEPTION 'BLEND_OUTPUT_FORM_NOT_BLENDABLE|%|%', v_mat.code, COALESCE(v_mat.form_code, '')
          USING HINT = '配料只混出可售的粉料(黑粉、正极粉、负极粉 —— 配料这道工序声明的产出形态)。先给这种物料选对形态,或换一种物料。';
    END IF;

    -- ② 合同
    IF p_source_contract_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM contracts c WHERE c.id = p_source_contract_id) THEN
        RAISE EXCEPTION 'BLEND_CONTRACT_NOT_FOUND|%', p_source_contract_id;
    END IF;

    DELETE FROM blending_plan_targets WHERE plan_id = p_plan_id;
    DELETE FROM blending_plan_lines WHERE plan_id = p_plan_id;

    -- ③ 目标
    IF p_targets IS NULL AND p_source_contract_id IS NOT NULL THEN
        INSERT INTO blending_plan_targets (plan_id, metal, min_pct, max_pct, source, source_grade_spec_id)
        SELECT DISTINCT ON (s.metal) p_plan_id, s.metal, s.min_pct, s.max_pct, 'contract', s.id
          FROM contract_grade_specs s
         WHERE s.contract_id = p_source_contract_id
           AND (s.material_id IS NULL OR s.material_id = p_output_material_id)
         ORDER BY s.metal, s.material_id NULLS LAST;
    ELSIF p_targets IS NOT NULL THEN
        IF jsonb_typeof(p_targets) <> 'array' THEN
            RAISE EXCEPTION 'BLEND_TARGETS_INVALID';
        END IF;
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_targets) LOOP
            IF NULLIF(v_el ->> 'grade_spec_id', '') IS NOT NULL THEN
                SELECT * INTO v_spec FROM contract_grade_specs s WHERE s.id = (v_el ->> 'grade_spec_id')::uuid;
                IF NOT FOUND OR p_source_contract_id IS NULL OR v_spec.contract_id <> p_source_contract_id THEN
                    RAISE EXCEPTION 'BLEND_TARGET_SPEC_NOT_FROM_CONTRACT|%', v_el ->> 'grade_spec_id'
                      USING HINT = '从合同抄的目标品位必须来自这份计划选的那一份合同。';
                END IF;
                IF v_spec.material_id IS NOT NULL AND v_spec.material_id <> p_output_material_id THEN
                    RAISE EXCEPTION 'BLEND_TARGET_SPEC_OTHER_MATERIAL|%|%', v_spec.metal,
                        (SELECT m.code FROM materials m WHERE m.id = v_spec.material_id)
                      USING HINT = '这一条品位规格是给另一种物料的,不适用于这份计划混出来的那一种。';
                END IF;
                v_metal := v_spec.metal;
                IF v_metal = ANY (v_metals) THEN
                    RAISE EXCEPTION 'BLEND_TARGET_DUPLICATE_METAL|%', v_metal;
                END IF;
                INSERT INTO blending_plan_targets (plan_id, metal, min_pct, max_pct, source, source_grade_spec_id)
                VALUES (p_plan_id, v_spec.metal, v_spec.min_pct, v_spec.max_pct, 'contract', v_spec.id);
            ELSE
                v_metal := NULLIF(btrim(COALESCE(v_el ->> 'metal', '')), '');
                IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances s WHERE s.code = v_metal) THEN
                    RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
                END IF;
                IF v_metal = ANY (v_metals) THEN
                    RAISE EXCEPTION 'BLEND_TARGET_DUPLICATE_METAL|%', v_metal;
                END IF;
                v_min := NULLIF(v_el ->> 'min_pct', '')::numeric;
                v_max := NULLIF(v_el ->> 'max_pct', '')::numeric;
                IF v_min IS NULL AND v_max IS NULL THEN
                    RAISE EXCEPTION 'BLEND_TARGET_NEEDS_A_BOUND|%', v_metal
                      USING HINT = '一条两边都不设限的目标什么也没规定。至少填下界或上界。';
                END IF;
                IF (v_min IS NOT NULL AND (v_min < 0 OR v_min > 100)) OR (v_max IS NOT NULL AND (v_max < 0 OR v_max > 100)) THEN
                    RAISE EXCEPTION 'BLEND_TARGET_PCT_INVALID|%', v_metal;
                END IF;
                IF v_min IS NOT NULL AND v_max IS NOT NULL AND v_min > v_max THEN
                    RAISE EXCEPTION 'BLEND_TARGET_BOUNDS_ORDER|%|%|%', v_metal, v_min, v_max;
                END IF;
                INSERT INTO blending_plan_targets (plan_id, metal, min_pct, max_pct, source, source_grade_spec_id)
                VALUES (p_plan_id, v_metal, v_min, v_max, 'manual', NULL);
            END IF;
            v_metals := v_metals || v_metal;
        END LOOP;
    END IF;

    -- ④ 批次
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'BLEND_NO_LINES';
    END IF;
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        v_ib := NULLIF(v_el ->> 'inbound_batch_id', '')::uuid;
        v_ob := NULLIF(v_el ->> 'output_batch_id', '')::uuid;
        IF (v_ib IS NULL) = (v_ob IS NULL) THEN
            RAISE EXCEPTION 'BLEND_LINE_ONE_BATCH';
        END IF;
        IF v_ib IS NOT NULL THEN
            SELECT b.code, b.unit, m.form_code INTO v_bcode, v_bunit, v_bform
              FROM inbound_batches b JOIN materials m ON m.id = b.material_id WHERE b.id = v_ib AND b.deleted_at IS NULL;
            IF NOT FOUND THEN RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_ib; END IF;
        ELSE
            SELECT b.code, b.unit, m.form_code INTO v_bcode, v_bunit, v_bform
              FROM output_batches b JOIN materials m ON m.id = b.material_id WHERE b.id = v_ob AND b.deleted_at IS NULL;
            IF NOT FOUND THEN RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_ob; END IF;
        END IF;
        IF v_bunit IS DISTINCT FROM 'kg' THEN
            RAISE EXCEPTION 'BLEND_LINE_UNIT_NOT_KG|%|%', v_bcode, COALESCE(v_bunit, '?');
        END IF;
        IF v_bform IS NULL OR NOT EXISTS (SELECT 1 FROM operation_type_input_forms i
                                           WHERE i.operation_type_code = 'blending' AND i.form_code = v_bform) THEN
            RAISE EXCEPTION 'BLEND_LINE_FORM_NOT_BLENDABLE|%|%', v_bcode, COALESCE(v_bform, '')
              USING HINT = '配料只收可售的粉料(黑粉、正极粉、负极粉 —— 配料这道工序声明的投料形态)。';
        END IF;
        v_kg := NULLIF(v_el ->> 'planned_kg', '')::numeric;
        IF v_kg IS NULL OR v_kg <= 0 THEN
            RAISE EXCEPTION 'BLEND_LINE_KG_INVALID|%', v_bcode;
        END IF;
        IF v_bcode = ANY (v_batches) THEN
            RAISE EXCEPTION 'BLEND_LINE_DUPLICATE_BATCH|%', v_bcode;
        END IF;
        v_batches := v_batches || v_bcode;
        INSERT INTO blending_plan_lines (plan_id, inbound_batch_id, output_batch_id, planned_kg)
        VALUES (p_plan_id, v_ib, v_ob, v_kg);
    END LOOP;
END;
$function$
