-- db/functions/share_weighbridge_ticket.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19 · Q20,Tim):【从地磅单页上分一份】—— 给一条发货行,或给一张【已经存在】的收货单。
--   恰好一个去处(TICKET_SHARE_TARGET_REQUIRED)。
--   · 发货行(Q20):持 action.ship_goods;发货、开票、过账一样都不动 —— 不挪钱。
--   · 已经存在的收货单(Q19):持 action.receive_goods;它的数量一个字都不动(建好之后本来就改不了),份与数量差多少照直显示。
--     建收货单【那一刻】给份(数量默认 = 份,改了要理由)走的是收货那两支函数,不是这里。
--   规则在 weighbridge_share_internal。返回那一份的 id。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.share_weighbridge_ticket(p_ticket_id uuid, p_kg numeric, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_shipment_line_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF num_nonnulls(p_inbound_batch_id, p_shipment_line_id) <> 1 THEN
        RAISE EXCEPTION 'TICKET_SHARE_TARGET_REQUIRED';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        PERFORM require_permission('action.receive_goods');
        IF NOT EXISTS (SELECT 1 FROM inbound_batches b WHERE b.id = p_inbound_batch_id AND b.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
        END IF;
    ELSE
        PERFORM require_permission('action.ship_goods');
        IF NOT EXISTS (SELECT 1 FROM shipment_lines l WHERE l.id = p_shipment_line_id) THEN
            RAISE EXCEPTION 'SHIPMENT_LINE_NOT_FOUND|%', p_shipment_line_id;
        END IF;
    END IF;
    RETURN weighbridge_share_internal(p_ticket_id, p_inbound_batch_id, p_shipment_line_id, p_kg, NULL);
END;
$function$;
