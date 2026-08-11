CREATE OR REPLACE FUNCTION public.guard_po_line_received_floor()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_received numeric;
    v_line record;
BEGIN
    v_line := CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;

    SELECT COALESCE(SUM(ib.quantity), 0) INTO v_received
    FROM inbound_batches ib
    WHERE ib.purchase_order_line_id = v_line.id AND ib.deleted_at IS NULL;

    IF TG_OP = 'DELETE' THEN
        -- 收过货的行不能删:那批货真的到了,单据上却没有它的出处
        IF v_received > 0 THEN
            RAISE EXCEPTION 'PO_LINE_HAS_RECEIPTS|%|%', OLD.line_no, v_received;
        END IF;
        RETURN OLD;
    END IF;

    -- 【下限是"已收",不是"零"】把订量砍到已收之下,等于让单据宣称我们订的
    -- 比实际到的还少 —— 而货已经在院子里了。等于已收是允许的(边界在内)。
    IF NEW.quantity < v_received THEN
        RAISE EXCEPTION 'PO_LINE_BELOW_RECEIVED|%|%|%', NEW.line_no, v_received, NEW.quantity;
    END IF;
    RETURN NEW;
END;
$function$;