-- db/functions/remove_review_goal.sql
-- 评估人删一条目标。【只在 draft】—— 自评开始之后删题,会把被评估人已经写下的回答一起抹掉。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.remove_review_goal(p_goal_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_g review_goals%ROWTYPE;
BEGIN
    SELECT * INTO v_g FROM review_goals WHERE id = p_goal_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOAL_NOT_FOUND|%', COALESCE(p_goal_id::text,'?'); END IF;
    -- 【只在 draft】自评开始之后删题,等于把被评估人已经写下的回答一起抹掉。
    PERFORM require_reviewer_of(v_g.review_id, ARRAY['draft']);
    DELETE FROM review_goals WHERE id = p_goal_id;
    RETURN jsonb_build_object('goal_id', p_goal_id, 'review_id', v_g.review_id, 'removed', true);
END;
$function$
;