-- db/functions/set_review_reviewer.sql
-- 补上/更换评估人。module.hr.edit;拒绝自评,也拒绝把已离职的人设成评估人。
-- 补上之后 hr_alerts 的 review_no_reviewer 【自动消失】—— 那条提醒是派生的,不是存储的,
-- 所以不存在"改了数据忘了清提醒"这种状态。
--
-- NOTE: introduced by db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql.

CREATE OR REPLACE FUNCTION public.set_review_reviewer(p_review_id uuid, p_reviewer_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r   performance_reviews%ROWTYPE;
    v_rev record;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF v_r.status = 'void' THEN
        RAISE EXCEPTION 'REVIEW_ALREADY_VOID|%', p_review_id;
    END IF;

    IF p_reviewer_employee_id IS NULL THEN
        RAISE EXCEPTION 'REVIEWER_REQUIRED';
    END IF;
    IF p_reviewer_employee_id = v_r.employee_id THEN
        RAISE EXCEPTION 'SELF_REVIEW_FORBIDDEN';
    END IF;

    SELECT id, code, employment_status INTO v_rev
    FROM employees WHERE id = p_reviewer_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    IF v_rev.employment_status = 'separated' THEN
        RAISE EXCEPTION 'REVIEWER_SEPARATED|%', v_rev.code;
    END IF;

    UPDATE performance_reviews
    SET reviewer_employee_id = p_reviewer_employee_id
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id,
                              'reviewer_employee_id', p_reviewer_employee_id,
                              'reviewer_code', v_rev.code,
                              'previous_reviewer', v_r.reviewer_employee_id);
END;
$function$
;