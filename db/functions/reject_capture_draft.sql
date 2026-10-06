-- db/functions/reject_capture_draft.sql
-- MES-2(2026-10-06,MES-0 Q13;MES-2 Step 0 Q10,Tim):【驳回】一张草稿 —— 理由必填,终局。
--   持 action.confirm_capture。驳回之后不落任何正式记录;收件箱那一行照旧是 transformed(它的守卫冻着它)。
--   一次被驳错的读数,由人手工再录一次(那一次照样记成 manual)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.reject_capture_draft(p_draft_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status text;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CAPTURE_REJECT_REASON_REQUIRED';
    END IF;
    SELECT status INTO v_status FROM capture_drafts WHERE id = p_draft_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_NOT_FOUND|%', COALESCE(p_draft_id::text, '?');
    END IF;
    IF v_status <> 'pending' THEN
        RAISE EXCEPTION 'CAPTURE_DRAFT_DECIDED|%', v_status;
    END IF;
    UPDATE capture_drafts SET status = 'rejected', rejected_at = now(), rejected_by = auth.uid(), reject_reason = btrim(p_reason)
     WHERE id = p_draft_id;
END;
$function$;
