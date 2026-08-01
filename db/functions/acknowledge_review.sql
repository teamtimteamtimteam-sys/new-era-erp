-- db/functions/acknowledge_review.sql
-- 员工确认已阅。只有被评估人本人能调,且只能从 approved 出发 ——
-- HR 替员工点「已阅」会把这个动作的全部意义抹掉,所以这里【不给 module.hr.edit 开口子】。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.

CREATE OR REPLACE FUNCTION public.acknowledge_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r performance_reviews%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF v_r.employee_id IS DISTINCT FROM current_user_employee() THEN
        RAISE EXCEPTION 'NOT_REVIEW_SUBJECT';
    END IF;

    IF v_r.status <> 'approved' THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    UPDATE performance_reviews
    SET status = 'acknowledged', acknowledged_at = now()
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'acknowledged');
END;
$function$
;