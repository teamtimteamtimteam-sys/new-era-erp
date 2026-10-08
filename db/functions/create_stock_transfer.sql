-- db/functions/create_stock_transfer.sql
-- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q19 · Q20,Tim):一批身上开着一个要隔离的状态(鼓包或漏液),
--   它的下一次移动只能进一个在用的隔离库位 —— 入腿过 assert_quarantine_landing,拒绝 QUARANTINE_LOCATION_REQUIRED。
--   移进隔离永远准许;从隔离移到另一个隔离也准许。签名不变。
-- MES-5a-1(2026-10-08):函数体搬进 create_stock_transfer_internal(同签名、同行为);这里只判码再转交 —— 拆去隔离要用同一份转移,
--   而它的门是 action.processing_aftercare。签名不变。

CREATE OR REPLACE FUNCTION public.create_stock_transfer(p_qty numeric, p_to_location_id uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_from_location_id uuid DEFAULT NULL::uuid, p_stock_status text DEFAULT 'available'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.inventory.edit');
    RETURN create_stock_transfer_internal(p_qty, p_to_location_id, p_inbound_batch_id, p_output_batch_id, p_from_location_id, p_stock_status, p_note);
END;
$function$
