-- db/functions/weighbridge_share_internal.sql
-- MES-2(2026-10-06,MES-0 Q19 · Q21;MES-2 Step 0 Q18 · Q19 · Q20,Tim):【把一张地磅单分一份出去 —— 内层】。
--   调用方:create_inbound_batch · receive_inbound_batch_against_po(建收货单那一刻,带数量的理由)· share_weighbridge_ticket(从单上分)。
--   只从一张【完成了的】、没作废的单分(TICKET_NOT_COMPLETE · TICKET_VOIDED);kg > 0(TICKET_SHARE_KG_INVALID);
--   方向要对 —— 进厂单分给收货单、出厂单分给发货行(TICKET_DIRECTION_MISMATCH|<编号>|<该是的方向>);同一个去处只分一次
--   (TICKET_ALREADY_SHARED|<编号>)。各份之和【不】对着净重设上限:差多少在单上照直显示,从不强迫相等(MES-0 Q19)。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.weighbridge_share_internal(p_ticket_id uuid, p_inbound_batch_id uuid, p_shipment_line_id uuid, p_kg numeric, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tk weighbridge_tickets%ROWTYPE;
    v_id uuid;
BEGIN
    SELECT * INTO v_tk FROM weighbridge_tickets WHERE id = p_ticket_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TICKET_NOT_FOUND|%', COALESCE(p_ticket_id::text, '?');
    END IF;
    IF v_tk.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_VOIDED|%', v_tk.code;
    END IF;
    IF v_tk.completed_at IS NULL THEN
        RAISE EXCEPTION 'TICKET_NOT_COMPLETE|%', v_tk.code;
    END IF;
    IF p_kg IS NULL OR p_kg <= 0 THEN
        RAISE EXCEPTION 'TICKET_SHARE_KG_INVALID';
    END IF;
    IF p_inbound_batch_id IS NOT NULL AND v_tk.direction <> 'inbound' THEN
        RAISE EXCEPTION 'TICKET_DIRECTION_MISMATCH|%|inbound', v_tk.code;
    END IF;
    IF p_shipment_line_id IS NOT NULL AND v_tk.direction <> 'outbound' THEN
        RAISE EXCEPTION 'TICKET_DIRECTION_MISMATCH|%|outbound', v_tk.code;
    END IF;
    IF EXISTS (SELECT 1 FROM weighbridge_ticket_shares s WHERE s.ticket_id = p_ticket_id
                  AND (s.inbound_batch_id = p_inbound_batch_id OR s.shipment_line_id = p_shipment_line_id)) THEN
        RAISE EXCEPTION 'TICKET_ALREADY_SHARED|%', v_tk.code;
    END IF;
    INSERT INTO weighbridge_ticket_shares (ticket_id, inbound_batch_id, shipment_line_id, kg, receipt_quantity_reason, created_by)
    VALUES (p_ticket_id, p_inbound_batch_id, p_shipment_line_id, p_kg, NULLIF(btrim(COALESCE(p_reason, '')), ''), auth.uid())
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;
