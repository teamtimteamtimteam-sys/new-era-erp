-- db/functions/update_review_goal.sql
-- 评估人改一条目标(objective/target/unit)。【只在 draft】,理由同上。
-- 只碰这三列:employee_result_text 与 actual_value 是被评估人的。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.update_review_goal(p_goal_id uuid, p_objective_text text, p_target_value numeric DEFAULT NULL::numeric, p_unit text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_g review_goals%ROWTYPE;
BEGIN
    SELECT * INTO v_g FROM review_goals WHERE id = p_goal_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOAL_NOT_FOUND|%', COALESCE(p_goal_id::text,'?'); END IF;
    PERFORM require_reviewer_of(v_g.review_id, ARRAY['draft']);
    IF p_objective_text IS NULL OR btrim(p_objective_text) = '' THEN
        RAISE EXCEPTION 'OBJECTIVE_REQUIRED';
    END IF;
    -- 【只碰这三列】employee_result_text 与 actual_value 是被评估人的,不在这里。
    UPDATE review_goals
    SET objective_text = btrim(p_objective_text),
        target_value   = p_target_value,
        unit           = NULLIF(btrim(p_unit), '')
    WHERE id = p_goal_id;
    RETURN jsonb_build_object('goal_id', p_goal_id, 'review_id', v_g.review_id);
END;
$function$
;