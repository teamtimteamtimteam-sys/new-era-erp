-- db/functions/set_review_conclusion.sql
-- 评估人写评级与书面结论。draft 与 self_review。
-- 【刻意不收 probation_outcome、不收薪酬、不动 status】:转正与否是 HR 的决定,
-- 调薪同理;提交走 submit_review,批准走 approve_review。
-- 【后果】评估人提交不了试用期评估 —— 那类评估自 submitted 起必须有结论,而结论他写不了。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.set_review_conclusion(p_review_id uuid, p_rating_code text, p_summary_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_reviewer_of(p_review_id, ARRAY['draft','self_review']);
    IF p_rating_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM review_rating_scale s
                       WHERE s.code = p_rating_code AND s.is_active) THEN
        RAISE EXCEPTION 'RATING_NOT_FOUND|%', p_rating_code;
    END IF;
    UPDATE performance_reviews
    SET rating_code  = p_rating_code,
        summary_text = p_summary_text
    WHERE id = p_review_id;
    RETURN jsonb_build_object('review_id', p_review_id, 'rating_code', p_rating_code);
END;
$function$
;