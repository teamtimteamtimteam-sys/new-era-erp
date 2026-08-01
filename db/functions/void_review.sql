-- db/functions/void_review.sql
-- 作废评估。评估是单据:更正靠【作废 + 重开】,不靠改一份已批准的(同发票那一套)。
-- 【作废不回滚已经发生的雇佣事实】—— 转正与调薪已经写进 employees 与不可变的
-- employment_history。要改那些,靠新的评估或 HR 手工更正再补一行,不靠把历史抹掉。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.

CREATE OR REPLACE FUNCTION public.void_review(p_review_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r performance_reviews%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF v_r.status = 'void' THEN
        RAISE EXCEPTION 'REVIEW_ALREADY_VOID|%', p_review_id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    UPDATE performance_reviews
    SET status = 'void', void_reason = btrim(p_reason),
        voided_at = now(), voided_by = auth.uid()
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'void',
                              'previous_status', v_r.status,
                              'employment_facts_unchanged', true);
END;
$function$
;