-- db/functions/set_supplier_score_settings.sql
-- MES-8a(2026-10-16,MES-0 Q93 · MES-8 Step 0 Q4 · Q5 · Q6,Tim):【设定 V23 与 V24】—— 整行替换(面板交的是四样的全部),门 action.supplier_review。
--   V23 weights      {<计分项>: 权重 ≥ 0},键正好是 supplier_scorecard_measure_keys()(SCORE_WEIGHT_MISSING|<项> · SCORE_WEIGHT_UNKNOWN|<项> ·
--                    SCORE_WEIGHT_INVALID|<项>);与 grade_lines 同进同出(SCORE_WEIGHTS_AND_LINES_TOGETHER)。
--       grade_lines  [{grade, max_score}],至少一条;等级不空、不重复(SCORE_GRADE_NAME_INVALID|<第几条> · SCORE_GRADE_DUPLICATE|<等级>);
--                    除最后一条外 max_score 是数且严格递增(SCORE_GRADE_LINE_INVALID|<第几条>);最后一条 max_score 必须是 null
--                    (SCORE_GRADE_LAST_LINE_OPEN —— 它接住比所有线都高的分,于是任何一个分都有一个等级)。
--       review_window_days  空或 > 0(SCORE_REVIEW_WINDOW_INVALID|<天>)。
--   V24 grade_caps   {<等级>: {prepayment_cap_pct, sampling_level}};键必须是等级线里的等级(SCORE_CAP_GRADE_UNKNOWN|<等级>);
--                    上限是 0–100 的数(SCORE_CAP_PCT_INVALID|<等级>);抽样级别是一句话。每一样都可以先空着 —— V24 那一行就挂着,直到两样都给了。
--   什么都不替谁选:空着就是 Not yet set。修改史在变更记录里(审计主语 supplier_score_settings)。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.set_supplier_score_settings(p_weights jsonb, p_grade_lines jsonb, p_review_window_days integer, p_grade_caps jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_keys   text[] := supplier_scorecard_measure_keys();
    v_k      text;
    v_lines  jsonb := '[]'::jsonb;
    v_caps   jsonb := NULL;
    v_l      jsonb;
    v_i      int := 0;
    v_n      int;
    v_grade  text;
    v_max    numeric;
    v_prev   numeric;
    v_grades text[] := ARRAY[]::text[];
    v_pct    numeric;
    v_level  text;
BEGIN
    PERFORM require_permission('action.supplier_review');
    IF p_weights = 'null'::jsonb THEN p_weights := NULL; END IF;
    IF p_grade_lines = 'null'::jsonb THEN p_grade_lines := NULL; END IF;
    IF p_grade_caps = 'null'::jsonb OR p_grade_caps = '{}'::jsonb THEN p_grade_caps := NULL; END IF;

    IF (p_weights IS NULL) <> (p_grade_lines IS NULL) THEN
        RAISE EXCEPTION 'SCORE_WEIGHTS_AND_LINES_TOGETHER';
    END IF;

    IF p_weights IS NOT NULL THEN
        IF jsonb_typeof(p_weights) <> 'object' THEN
            RAISE EXCEPTION 'SCORE_WEIGHT_INVALID|?';
        END IF;
        FOREACH v_k IN ARRAY v_keys LOOP
            IF NOT (p_weights ? v_k) THEN
                RAISE EXCEPTION 'SCORE_WEIGHT_MISSING|%', v_k;
            END IF;
            IF jsonb_typeof(p_weights -> v_k) <> 'number' OR (p_weights ->> v_k)::numeric < 0 THEN
                RAISE EXCEPTION 'SCORE_WEIGHT_INVALID|%', v_k;
            END IF;
        END LOOP;
        SELECT k INTO v_k FROM jsonb_object_keys(p_weights) k WHERE NOT (k = ANY (v_keys)) ORDER BY k LIMIT 1;
        IF v_k IS NOT NULL THEN
            RAISE EXCEPTION 'SCORE_WEIGHT_UNKNOWN|%', v_k;
        END IF;

        IF jsonb_typeof(p_grade_lines) <> 'array' OR jsonb_array_length(p_grade_lines) = 0 THEN
            RAISE EXCEPTION 'SCORE_GRADE_LINE_INVALID|0';
        END IF;
        v_n := jsonb_array_length(p_grade_lines);
        FOR v_l IN SELECT e FROM jsonb_array_elements(p_grade_lines) e LOOP
            v_i := v_i + 1;
            v_grade := NULLIF(btrim(COALESCE(v_l ->> 'grade', '')), '');
            IF v_grade IS NULL THEN
                RAISE EXCEPTION 'SCORE_GRADE_NAME_INVALID|%', v_i;
            END IF;
            IF v_grade = ANY (v_grades) THEN
                RAISE EXCEPTION 'SCORE_GRADE_DUPLICATE|%', v_grade;
            END IF;
            v_grades := v_grades || v_grade;
            IF v_i = v_n THEN
                IF (v_l -> 'max_score') IS NOT NULL AND (v_l -> 'max_score') <> 'null'::jsonb THEN
                    RAISE EXCEPTION 'SCORE_GRADE_LAST_LINE_OPEN';
                END IF;
                v_max := NULL;
            ELSE
                IF jsonb_typeof(v_l -> 'max_score') IS DISTINCT FROM 'number' THEN
                    RAISE EXCEPTION 'SCORE_GRADE_LINE_INVALID|%', v_i;
                END IF;
                v_max := (v_l ->> 'max_score')::numeric;
                IF v_max < 0 OR (v_prev IS NOT NULL AND v_max <= v_prev) THEN
                    RAISE EXCEPTION 'SCORE_GRADE_LINE_INVALID|%', v_i;
                END IF;
                v_prev := v_max;
            END IF;
            v_lines := v_lines || jsonb_build_array(jsonb_build_object('grade', v_grade, 'max_score', v_max));
        END LOOP;
    ELSE
        v_lines := NULL;
    END IF;

    IF p_review_window_days IS NOT NULL AND p_review_window_days <= 0 THEN
        RAISE EXCEPTION 'SCORE_REVIEW_WINDOW_INVALID|%', p_review_window_days;
    END IF;

    IF p_grade_caps IS NOT NULL THEN
        IF v_lines IS NULL THEN
            RAISE EXCEPTION 'SCORE_CAP_GRADE_UNKNOWN|%', (SELECT k FROM jsonb_object_keys(p_grade_caps) k ORDER BY k LIMIT 1);
        END IF;
        IF jsonb_typeof(p_grade_caps) <> 'object' THEN
            RAISE EXCEPTION 'SCORE_CAP_GRADE_UNKNOWN|?';
        END IF;
        v_caps := '{}'::jsonb;
        FOR v_k IN SELECT k FROM jsonb_object_keys(p_grade_caps) k ORDER BY k LOOP
            v_grade := btrim(v_k);
            IF NOT (v_grade = ANY (v_grades)) THEN
                RAISE EXCEPTION 'SCORE_CAP_GRADE_UNKNOWN|%', v_k;
            END IF;
            v_pct := NULL;
            IF (p_grade_caps -> v_k -> 'prepayment_cap_pct') IS NOT NULL AND (p_grade_caps -> v_k -> 'prepayment_cap_pct') <> 'null'::jsonb THEN
                IF jsonb_typeof(p_grade_caps -> v_k -> 'prepayment_cap_pct') <> 'number' THEN
                    RAISE EXCEPTION 'SCORE_CAP_PCT_INVALID|%', v_grade;
                END IF;
                v_pct := (p_grade_caps -> v_k ->> 'prepayment_cap_pct')::numeric;
                IF v_pct < 0 OR v_pct > 100 THEN
                    RAISE EXCEPTION 'SCORE_CAP_PCT_INVALID|%', v_grade;
                END IF;
            END IF;
            v_level := NULLIF(btrim(COALESCE(p_grade_caps -> v_k ->> 'sampling_level', '')), '');
            v_caps := v_caps || jsonb_build_object(v_grade, jsonb_build_object('prepayment_cap_pct', v_pct, 'sampling_level', v_level));
        END LOOP;
    END IF;

    UPDATE supplier_score_settings
       SET weights = p_weights, grade_lines = v_lines, review_window_days = p_review_window_days,
           grade_caps = v_caps, updated_by = auth.uid()
     WHERE id;

    RETURN jsonb_build_object('weights', p_weights, 'grade_lines', v_lines,
                              'review_window_days', p_review_window_days, 'grade_caps', v_caps);
END;
$function$
