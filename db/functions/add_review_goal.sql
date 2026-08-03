-- db/functions/add_review_goal.sql
-- 评估人新增一条目标。【只在 draft】—— 自评一开,被评估人就在对着题作答。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.add_review_goal(p_review_id uuid, p_objective_text text, p_target_value numeric DEFAULT NULL::numeric, p_unit text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_seq integer; v_id uuid;
BEGIN
    PERFORM require_reviewer_of(p_review_id, ARRAY['draft']);
    IF p_objective_text IS NULL OR btrim(p_objective_text) = '' THEN
        RAISE EXCEPTION 'OBJECTIVE_REQUIRED';
    END IF;
    SELECT COALESCE(max(sequence), 0) + 1 INTO v_seq FROM review_goals WHERE review_id = p_review_id;
    INSERT INTO review_goals (review_id, sequence, objective_text, target_value, unit)
    VALUES (p_review_id, v_seq, btrim(p_objective_text), p_target_value, NULLIF(btrim(p_unit), ''))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('goal_id', v_id, 'review_id', p_review_id, 'sequence', v_seq);
END;
$function$
;