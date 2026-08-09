CREATE OR REPLACE FUNCTION public.submit_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      performance_reviews%ROWTYPE;
    v_goals  integer;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF NOT (has_permission('module.hr.edit')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    -- self_review 是可选的一步,所以两个入口状态都收
    IF v_r.status NOT IN ('draft','self_review') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    IF v_r.reviewer_employee_id IS NULL THEN
        RAISE EXCEPTION 'REVIEWER_REQUIRED';
    END IF;
    IF v_r.rating_code IS NULL THEN
        RAISE EXCEPTION 'RATING_REQUIRED';
    END IF;
    IF v_r.summary_text IS NULL OR btrim(v_r.summary_text) = '' THEN
        RAISE EXCEPTION 'SUMMARY_REQUIRED';
    END IF;
    IF v_r.review_type = 'probation' AND v_r.probation_outcome IS NULL THEN
        RAISE EXCEPTION 'PROBATION_OUTCOME_REQUIRED';
    END IF;

    SELECT count(*) INTO v_goals FROM review_goals WHERE review_id = p_review_id;
    IF v_goals = 0 THEN
        RAISE EXCEPTION 'GOALS_REQUIRED';
    END IF;

    UPDATE performance_reviews
    SET status = 'submitted', submitted_at = now(), submitted_by = auth.uid()
    WHERE id = p_review_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('performance_review', p_review_id, 'submitted', NULL, NULL);

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'submitted',
                              'rating_code', v_r.rating_code, 'goals', v_goals);
END;
$function$;