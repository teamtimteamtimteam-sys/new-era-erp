-- db/functions/withdraw_ticket_photo.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q21,Tim):【撤下一张拍错的照片】—— 理由必填(TICKET_PHOTO_WITHDRAW_REASON_REQUIRED);
--   行与桶里的对象都留着(桶不许删,行的守卫不许删),只是页面上不再当成这张单的照片。持 action.confirm_capture。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.withdraw_ticket_photo(p_photo_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_withdrawn timestamptz;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'TICKET_PHOTO_WITHDRAW_REASON_REQUIRED';
    END IF;
    SELECT withdrawn_at INTO v_withdrawn FROM weighbridge_ticket_photos WHERE id = p_photo_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TICKET_PHOTO_NOT_FOUND|%', COALESCE(p_photo_id::text, '?');
    END IF;
    IF v_withdrawn IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_PHOTO_WITHDRAWN|%', p_photo_id;
    END IF;
    UPDATE weighbridge_ticket_photos SET withdrawn_at = now(), withdrawn_by = auth.uid(), withdraw_reason = btrim(p_reason)
     WHERE id = p_photo_id;
END;
$function$;
