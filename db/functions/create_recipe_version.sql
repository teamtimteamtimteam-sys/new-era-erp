-- db/functions/create_recipe_version.sql
-- MES-4a(2026-10-07,MES-0 Q44;MES-4a Step 0 Q16,Tim):【给一个配方出新的一版】—— 一版写了就不改,改配方 = 出下一版。
--   持 module.processing.edit。配方必须存在且启用着(RECIPE_NOT_FOUND · RECIPE_INACTIVE)。p_values = {字段码: 值},不能是空的
--   (RECIPE_VALUES_REQUIRED);每一个键必须是这道工序上【启用着的参数】(RECIPE_FIELD_NOT_A_PARAMETER|<字段>)—— 指标是这一炉出来的
--   结果,不是预设;每个值按字段的类型验(数 · 计数 · 文字 · 是/否 → RECIPE_VALUE_INVALID|<字段>|<类型>)。存的是规整过的值
--   (数是 jsonb 数,是/否是 jsonb 布尔)。版本号 = 这个配方已有的最大版本 + 1(加锁,两次并发不会撞号)。返回新一版的 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.create_recipe_version(p_recipe_id uuid, p_values jsonb, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rc   process_recipes%ROWTYPE;
    v_f    operation_type_fields%ROWTYPE;
    v_key  text;
    v_val  jsonb;
    v_out  jsonb := '{}'::jsonb;
    v_num  numeric;
    v_ver  integer;
    v_id   uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_rc FROM process_recipes WHERE id = p_recipe_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECIPE_NOT_FOUND|%', p_recipe_id;
    END IF;
    IF NOT v_rc.is_active THEN
        RAISE EXCEPTION 'RECIPE_INACTIVE|%', v_rc.code;
    END IF;
    IF p_values IS NULL OR jsonb_typeof(p_values) <> 'object' OR p_values = '{}'::jsonb THEN
        RAISE EXCEPTION 'RECIPE_VALUES_REQUIRED';
    END IF;
    FOR v_key IN SELECT k FROM jsonb_object_keys(p_values) k ORDER BY k LOOP
        SELECT * INTO v_f FROM operation_type_fields f
         WHERE f.operation_type_code = v_rc.operation_type_code AND f.field_code = v_key AND f.is_active AND f.kind = 'parameter';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RECIPE_FIELD_NOT_A_PARAMETER|%', v_key;
        END IF;
        v_val := p_values -> v_key;
        IF v_f.value_type IN ('number', 'count') THEN
            BEGIN
                v_num := CASE jsonb_typeof(v_val) WHEN 'number' THEN (v_val #>> '{}')::numeric
                                                   WHEN 'string' THEN NULLIF(btrim(v_val #>> '{}'), '')::numeric END;
            EXCEPTION WHEN others THEN
                v_num := NULL;
            END;
            IF v_num IS NULL OR (v_f.value_type = 'count' AND (v_num < 0 OR v_num <> trunc(v_num))) THEN
                RAISE EXCEPTION 'RECIPE_VALUE_INVALID|%|%', v_key, v_f.value_type;
            END IF;
            v_out := v_out || jsonb_build_object(v_key, v_num);
        ELSIF v_f.value_type = 'text' THEN
            IF NULLIF(btrim(v_val #>> '{}'), '') IS NULL THEN
                RAISE EXCEPTION 'RECIPE_VALUE_INVALID|%|%', v_key, v_f.value_type;
            END IF;
            v_out := v_out || jsonb_build_object(v_key, btrim(v_val #>> '{}'));
        ELSE
            IF jsonb_typeof(v_val) = 'boolean' THEN
                v_out := v_out || jsonb_build_object(v_key, (v_val #>> '{}')::boolean);
            ELSIF lower(v_val #>> '{}') IN ('true', 'yes') THEN
                v_out := v_out || jsonb_build_object(v_key, true);
            ELSIF lower(v_val #>> '{}') IN ('false', 'no') THEN
                v_out := v_out || jsonb_build_object(v_key, false);
            ELSE
                RAISE EXCEPTION 'RECIPE_VALUE_INVALID|%|%', v_key, v_f.value_type;
            END IF;
        END IF;
    END LOOP;
    SELECT COALESCE(max(version), 0) + 1 INTO v_ver FROM process_recipe_versions WHERE recipe_id = p_recipe_id;
    INSERT INTO process_recipe_versions (recipe_id, version, param_values, notes)
    VALUES (p_recipe_id, v_ver, v_out, NULLIF(btrim(COALESCE(p_notes, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
