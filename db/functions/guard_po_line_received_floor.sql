CREATE OR REPLACE FUNCTION public.guard_po_line_received_floor()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_received numeric;
    v_line record;
    v_exp record;
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
        -- EQP-1b-ii:报销过的行也不能删 —— 设备行没有收货,上面那条对它恒为假,
        -- 于是在本刀之前它一律删得掉。已冲销的照样拦(外键不认 status),
        -- 所以消息把状态一并说出来,让"为什么还拦着"是可读的。
        SELECT e.code, e.status INTO v_exp
        FROM expenses e
        WHERE e.purchase_order_line_id = OLD.id
        ORDER BY (e.status = 'posted') DESC, e.created_at
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'PO_LINE_HAS_EXPENSE|%|%|%', OLD.line_no, v_exp.code, v_exp.status;
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