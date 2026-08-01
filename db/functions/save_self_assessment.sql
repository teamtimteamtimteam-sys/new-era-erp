-- db/functions/save_self_assessment.sql
-- 员工写自评。【只有被评估人本人能调 —— HR 与评估人都不行】。
-- 这是本仓库里唯一一个【不带】"has_permission(...) OR 本人"那半句的自助函数:
-- 一份别人代写的自评没有价值,那正是这份文书唯一的作用所在。
--
-- 【写得到什么由函数的形状决定,不由调用方的自觉决定】:只 UPDATE
-- performance_reviews.self_assessment_text 与 review_goals.employee_result_text,
-- 全是静态 SQL、无一处动态拼接,因此 objective_text / reviewer_assessment_text /
-- rating_code / summary_text / probation_outcome / 薪酬两列 / status 在【结构上】够不到。
--
-- p_goal_results 形如 '[{"goal_id":"<uuid>","result_text":"..."}]';每个 goal_id 必须
-- 属于本评估。幂等:起草期间可反复调用,每次整份覆盖。p_final = true 落定稿时点并锁死。
--
-- NOTE: introduced by db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql.

CREATE OR REPLACE FUNCTION public.save_self_assessment(p_review_id uuid, p_self_assessment_text text, p_goal_results jsonb DEFAULT NULL::jsonb, p_final boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r       performance_reviews%ROWTYPE;
    v_me      uuid := current_user_employee();
    v_el      jsonb;
    v_goal_id uuid;
    v_n       integer := 0;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    -- 本人,且只有本人
    IF v_me IS NULL OR v_r.employee_id IS DISTINCT FROM v_me THEN
        RAISE EXCEPTION 'NOT_REVIEW_SUBJECT';
    END IF;

    IF v_r.status <> 'self_review' THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    IF v_r.self_assessment_submitted_at IS NOT NULL THEN
        RAISE EXCEPTION 'SELF_ASSESSMENT_LOCKED|%', v_r.self_assessment_submitted_at;
    END IF;

    IF p_goal_results IS NOT NULL THEN
        IF jsonb_typeof(p_goal_results) <> 'array' THEN
            RAISE EXCEPTION 'GOAL_RESULTS_NOT_ARRAY';
        END IF;
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_goal_results) LOOP
            v_goal_id := (v_el->>'goal_id')::uuid;
            IF v_goal_id IS NULL THEN
                RAISE EXCEPTION 'GOAL_ID_REQUIRED';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM review_goals g
                           WHERE g.id = v_goal_id AND g.review_id = p_review_id) THEN
                RAISE EXCEPTION 'GOAL_NOT_IN_REVIEW|%', v_goal_id;
            END IF;
            UPDATE review_goals
            SET employee_result_text = v_el->>'result_text'
            WHERE id = v_goal_id;
            v_n := v_n + 1;
        END LOOP;
    END IF;

    UPDATE performance_reviews
    SET self_assessment_text = p_self_assessment_text,
        self_assessment_submitted_at = CASE WHEN p_final THEN now() ELSE NULL END
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', v_r.status,
                              'goals_written', v_n, 'final', p_final,
                              'self_assessment_submitted_at',
                              (SELECT self_assessment_submitted_at FROM performance_reviews
                                WHERE id = p_review_id));
END;
$function$
;