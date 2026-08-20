CREATE OR REPLACE FUNCTION public.guard_inbound_po_line_match()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line_po uuid;
    v_asset   uuid;
BEGIN
    IF NEW.purchase_order_line_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT purchase_order_id, asset_id INTO v_line_po, v_asset
    FROM purchase_order_lines WHERE id = NEW.purchase_order_line_id;
    -- 给了明细行却没给 PO,或明细行不属于所给的 PO —— 两种都是挂错单
    IF v_line_po IS NULL OR NEW.purchase_order_id IS DISTINCT FROM v_line_po THEN
        RAISE EXCEPTION 'PO_LINE_MISMATCH|%', NEW.code;
    END IF;
    -- EQP-1a:设备行不可收货
    IF v_asset IS NOT NULL THEN
        RAISE EXCEPTION 'PO_LINE_EQUIPMENT_NOT_RECEIVABLE|%', NEW.code
          USING HINT = '这一行订的是一台机器 —— 机器到货不是一次入库(不产生批次、没有化验、不进库位)。它"到货"记在资产卡的投用日上。';
    END IF;
    RETURN NEW;
END;
$function$

