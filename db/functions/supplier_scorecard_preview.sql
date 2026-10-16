-- db/functions/supplier_scorecard_preview.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q2 · Q4):【一次评审若此刻记下,它会抄下什么】—— 计数(supplier_scorecard_measures)+ 此刻生效的 V23 / V24 +
--   由它们算出的分与等级(supplier_scorecard_grade)。评审表单显示它;record_supplier_review 调的就是它 —— 一份实现,两个调用者
--   (AGENTS.md「预览一次过账,就去问数据库它会是什么」)。门跟着计数那一支:module.suppliers.view。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.supplier_scorecard_preview(p_supplier_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_m  jsonb;
    v_s  supplier_score_settings%ROWTYPE;
    v_g  jsonb;
BEGIN
    PERFORM require_permission('module.suppliers.view');
    v_m := supplier_scorecard_measures(p_supplier_id, p_from, p_to);
    SELECT * INTO v_s FROM supplier_score_settings WHERE id;
    v_g := supplier_scorecard_grade(v_m, v_s.weights, v_s.grade_lines);
    RETURN jsonb_build_object(
        'measures',          v_m,
        'weights',           v_s.weights,
        'grade_lines',       v_s.grade_lines,
        'grade_caps',        v_s.grade_caps,
        'score',             v_g -> 'score',
        'grade',             v_g -> 'grade',
        'not_graded_reason', v_g -> 'not_graded_reason',
        'grade_advice',      CASE WHEN v_g ->> 'grade' IS NOT NULL THEN v_s.grade_caps -> (v_g ->> 'grade') END);
END;
$function$
