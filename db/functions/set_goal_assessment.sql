-- db/functions/set_goal_assessment.sql
-- 评估人写某条目标的评语。draft 与 self_review 都收 ——
-- 真实流程是自评定稿之后评估人才落笔,而那时状态仍是 self_review。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.set_goal_assessment(p_goal_id uuid, p_reviewer_assessment_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_g review_goals%ROWTYPE;
BEGIN
    SELECT * INTO v_g FROM review_goals WHERE id = p_goal_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOAL_NOT_FOUND|%', COALESCE(p_goal_id::text,'?'); END IF;
    -- 自评定稿之后评估人才落笔,而那时状态仍是 self_review,所以两个状态都要收。
    PERFORM require_reviewer_of(v_g.review_id, ARRAY['draft','self_review']);
    UPDATE review_goals SET reviewer_assessment_text = p_reviewer_assessment_text WHERE id = p_goal_id;
    RETURN jsonb_build_object('goal_id', p_goal_id, 'review_id', v_g.review_id);
END;
$function$
;