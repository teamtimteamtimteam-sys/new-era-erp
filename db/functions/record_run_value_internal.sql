-- db/functions/record_run_value_internal.sql
-- MES-4a(2026-10-07,MES-0 Q43;MES-4a Step 0 Q10–Q12 · Q29,Tim):【给一炉记一个值,或更正一个值】—— 内层,一份判据三个调用方:
--   commit_processing_run(提交时的值与配方预填)· record_run_value · correct_run_value(之后在加工单页上)。
--   ① 字段必须属于这一炉的工序(RUN_VALUE_FIELD_NOT_ON_OPERATION|<字段>|<工序>);【新记】一个值时字段必须启用着(RUN_VALUE_FIELD_RETIRED|<字段>)
--      —— 更正一个旧值不看它(退役不冻结历史)。
--   ② 新记时这一炉这个字段已经有一个当前值 → RUN_VALUE_ALREADY_RECORDED|<字段>(要改就更正它,不是再记一条)。
--   ③ 值按字段的类型验:number → 数 · count → 不小于 0 的整数 · text → 非空文字 · yes_no → true / false;不对 → RUN_VALUE_INVALID|<字段>|<类型>。
--      更正时可以给 null = 撤回(三列都空)。
--   ④ 记下那一刻抄进字段的范围(range_min_at / range_max_at)—— 越出它照记,out_of_range 由表上的生成列算出来(不拒,Q12)。
--   ⑤ 更正:被更正的那一行必须是这一炉的、而且是链的末端(RUN_VALUE_SUPERSEDED|<id>);理由必填(RUN_VALUE_CORRECTION_REASON_REQUIRED)。
--   返回新行的 id。【内层】不是 SECURITY DEFINER、没有调用者检查;EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.record_run_value_internal(p_run_id uuid, p_field_code text, p_value jsonb, p_source text, p_corrects bigint, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_op    text;
    v_f     operation_type_fields%ROWTYPE;
    v_orig  processing_run_values%ROWTYPE;
    v_num   numeric;
    v_txt   text;
    v_bool  boolean;
    v_id    bigint;
BEGIN
    SELECT r.operation_type_code INTO v_op FROM processing_runs r WHERE r.id = p_run_id;
    IF p_corrects IS NOT NULL THEN
        SELECT * INTO v_orig FROM processing_run_values v WHERE v.id = p_corrects AND v.run_id = p_run_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RUN_VALUE_NOT_FOUND|%', p_corrects;
        END IF;
        IF EXISTS (SELECT 1 FROM processing_run_values x WHERE x.corrects_id = v_orig.id) THEN
            RAISE EXCEPTION 'RUN_VALUE_SUPERSEDED|%', v_orig.id;
        END IF;
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
            RAISE EXCEPTION 'RUN_VALUE_CORRECTION_REASON_REQUIRED';
        END IF;
        p_field_code := v_orig.field_code;
    END IF;
    SELECT * INTO v_f FROM operation_type_fields f WHERE f.operation_type_code = v_op AND f.field_code = p_field_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_VALUE_FIELD_NOT_ON_OPERATION|%|%', COALESCE(p_field_code, '?'), COALESCE(v_op, '?');
    END IF;
    IF p_corrects IS NULL THEN
        IF NOT v_f.is_active THEN
            RAISE EXCEPTION 'RUN_VALUE_FIELD_RETIRED|%', p_field_code;
        END IF;
        IF EXISTS (SELECT 1 FROM processing_run_values v
                    WHERE v.run_id = p_run_id AND v.field_code = p_field_code
                      AND NOT EXISTS (SELECT 1 FROM processing_run_values x WHERE x.corrects_id = v.id)) THEN
            RAISE EXCEPTION 'RUN_VALUE_ALREADY_RECORDED|%', p_field_code;
        END IF;
    END IF;

    IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN
        IF p_corrects IS NULL THEN
            RAISE EXCEPTION 'RUN_VALUE_INVALID|%|%', p_field_code, v_f.value_type;
        END IF;
    ELSIF v_f.value_type IN ('number', 'count') THEN
        BEGIN
            v_num := CASE jsonb_typeof(p_value) WHEN 'number' THEN (p_value #>> '{}')::numeric
                                                 WHEN 'string' THEN NULLIF(btrim(p_value #>> '{}'), '')::numeric END;
        EXCEPTION WHEN others THEN
            v_num := NULL;
        END;
        IF v_num IS NULL OR (v_f.value_type = 'count' AND (v_num < 0 OR v_num <> trunc(v_num))) THEN
            RAISE EXCEPTION 'RUN_VALUE_INVALID|%|%', p_field_code, v_f.value_type;
        END IF;
    ELSIF v_f.value_type = 'text' THEN
        v_txt := NULLIF(btrim(p_value #>> '{}'), '');
        IF v_txt IS NULL THEN
            RAISE EXCEPTION 'RUN_VALUE_INVALID|%|%', p_field_code, v_f.value_type;
        END IF;
    ELSE
        v_bool := CASE WHEN jsonb_typeof(p_value) = 'boolean' THEN (p_value #>> '{}')::boolean
                       WHEN lower(p_value #>> '{}') IN ('true', 'yes') THEN true
                       WHEN lower(p_value #>> '{}') IN ('false', 'no') THEN false END;
        IF v_bool IS NULL THEN
            RAISE EXCEPTION 'RUN_VALUE_INVALID|%|%', p_field_code, v_f.value_type;
        END IF;
    END IF;

    INSERT INTO processing_run_values (run_id, operation_type_code, field_code, value_number, value_text, value_bool,
                                       range_min_at, range_max_at, source, corrects_id, correction_reason)
    VALUES (p_run_id, v_op, p_field_code, v_num, v_txt, v_bool,
            CASE WHEN v_f.has_range THEN v_f.range_min END, CASE WHEN v_f.has_range THEN v_f.range_max END,
            COALESCE(p_source, 'manual'), p_corrects, NULLIF(btrim(COALESCE(p_reason, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
