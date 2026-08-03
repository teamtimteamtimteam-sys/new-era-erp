-- db/functions/open_for_self_assessment.sql
-- 开启(或【重开】)自评:评估人或 module.hr.edit,draft / self_review → self_review。
-- 已定稿的自评从这里重开(清掉 self_assessment_submitted_at)—— 重开是评估人的决定。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-reviewer-write-path.sql;

CREATE OR REPLACE FUNCTION public.open_for_self_assessment(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r        performance_reviews%ROWTYPE;
    v_reopened boolean := false;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF NOT (has_permission('module.hr.edit')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    IF v_r.status NOT IN ('draft','self_review') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    v_reopened := (v_r.status = 'self_review' AND v_r.self_assessment_submitted_at IS NOT NULL);

    UPDATE performance_reviews
    SET status = 'self_review', self_assessment_submitted_at = NULL
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'self_review',
                              'previous_status', v_r.status, 'reopened', v_reopened);
END;
$function$
;