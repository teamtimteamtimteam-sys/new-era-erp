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

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('performance_review', p_review_id, 'acknowledged', NULL, NULL);

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'acknowledged');
END;
$function$;