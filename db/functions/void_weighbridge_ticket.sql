-- db/functions/void_weighbridge_ticket.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q16,Tim):【作废一张地磅单】—— 理由必填,而且只在它一份都没分出去的时候(TICKET_HAS_SHARES|<编号>)。
--   持 action.confirm_capture。作废之后冻住(守卫);它的称重留着(只追加),不再能完成、不再能分、不再能更正。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.void_weighbridge_ticket(p_ticket_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tk weighbridge_tickets%ROWTYPE;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'TICKET_VOID_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_tk FROM weighbridge_tickets WHERE id = p_ticket_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TICKET_NOT_FOUND|%', COALESCE(p_ticket_id::text, '?');
    END IF;
    IF v_tk.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_VOIDED|%', v_tk.code;
    END IF;
    IF EXISTS (SELECT 1 FROM weighbridge_ticket_shares s WHERE s.ticket_id = p_ticket_id) THEN
        RAISE EXCEPTION 'TICKET_HAS_SHARES|%', v_tk.code;
    END IF;
    UPDATE weighbridge_tickets
       SET voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason), updated_by = auth.uid()
     WHERE id = p_ticket_id;
END;
$function$;
