-- db/functions/supplier_scorecard_grade.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q2 · Q4):【由抄下来的计数、权重与等级线算出分与等级】—— 纯函数,一处实现;预览与记评审都调它。
--   分 = Σ 权重 × 那一项的 count;一项的 count 是 null("not compared")时它不计分(没比过的不算这一家的错,评审把 null 原样抄下)。
--   等级 = 按 max_score 升序的第一条 max_score ≥ 分(或 max_score 为 null —— 最后那条接住其余)的线。
--   权重或线是 null(V23 没给)→ {score: null, grade: null, not_graded_reason: 'V23_NOT_SET'} —— 什么都不猜。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.supplier_scorecard_grade(p_measures jsonb, p_weights jsonb, p_grade_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_score numeric;
    v_grade text;
BEGIN
    IF p_weights IS NULL OR p_grade_lines IS NULL THEN
        RETURN jsonb_build_object('score', NULL, 'grade', NULL, 'not_graded_reason', 'V23_NOT_SET');
    END IF;
    SELECT COALESCE(sum((p_weights ->> k)::numeric * ((p_measures -> 'scored' -> k) ->> 'count')::numeric)
                    FILTER (WHERE ((p_measures -> 'scored' -> k) ->> 'count') IS NOT NULL), 0)
      INTO v_score
      FROM unnest(supplier_scorecard_measure_keys()) k;
    SELECT l ->> 'grade' INTO v_grade
      FROM jsonb_array_elements(p_grade_lines) WITH ORDINALITY AS e(l, i)
     WHERE (l ->> 'max_score') IS NULL OR v_score <= (l ->> 'max_score')::numeric
     ORDER BY (l ->> 'max_score') IS NULL, (l ->> 'max_score')::numeric, i
     LIMIT 1;
    RETURN jsonb_build_object('score', v_score, 'grade', v_grade, 'not_graded_reason', NULL);
END;
$function$
