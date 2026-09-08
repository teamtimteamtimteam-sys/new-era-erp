CREATE OR REPLACE FUNCTION public.trg_po_history_line()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reason text := NULLIF(current_setting('evoltrya.amend_reason', true), '');
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- 【建单时的那一批行不记】否则每张新单都会先长出一份"全是新增"的历史,
        -- 把真正的修改埋掉。建单本身有 approval_log 的 auto_approved / submitted。
        IF current_setting('evoltrya.po_amend_ctx', true) IS DISTINCT FROM '1' THEN
            RETURN NEW;
        END IF;
        INSERT INTO purchase_order_history (purchase_order_id, purchase_order_line_id,
            line_no, change_type, new_quantity, new_unit,
            new_estimated_unit_price, new_estimated_amount_ccy, new_price_status, amend_reason)
        VALUES (NEW.purchase_order_id, NEW.id, NEW.line_no, 'line_add',
            NEW.quantity, NEW.unit, NEW.estimated_unit_price, NEW.estimated_amount_ccy,
            NEW.price_status, v_reason);
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO purchase_order_history (purchase_order_id, purchase_order_line_id,
            line_no, change_type, old_quantity, old_unit,
            old_estimated_unit_price, old_estimated_amount_ccy, old_price_status, amend_reason)
        VALUES (OLD.purchase_order_id, OLD.id, OLD.line_no, 'line_remove',
            OLD.quantity, OLD.unit, OLD.estimated_unit_price, OLD.estimated_amount_ccy,
            OLD.price_status, v_reason);
        RETURN OLD;
    END IF;

    IF NEW.quantity IS NOT DISTINCT FROM OLD.quantity
       AND NEW.unit IS NOT DISTINCT FROM OLD.unit
       AND NEW.estimated_unit_price IS NOT DISTINCT FROM OLD.estimated_unit_price
       AND NEW.estimated_amount_ccy IS NOT DISTINCT FROM OLD.estimated_amount_ccy
       -- PUR-1:定价状态是【一个人做出的选择】,改了它而档案沉默,
       -- 与数量、单价被改而档案沉默是同一件事。
       AND NEW.price_status IS NOT DISTINCT FROM OLD.price_status THEN
        RETURN NEW;
    END IF;
    INSERT INTO purchase_order_history (purchase_order_id, purchase_order_line_id,
        line_no, change_type,
        old_quantity, new_quantity, old_unit, new_unit,
        old_estimated_unit_price, new_estimated_unit_price,
        old_estimated_amount_ccy, new_estimated_amount_ccy,
        old_price_status, new_price_status, amend_reason)
    VALUES (NEW.purchase_order_id, NEW.id, NEW.line_no, 'line_update',
        OLD.quantity, NEW.quantity, OLD.unit, NEW.unit,
        OLD.estimated_unit_price, NEW.estimated_unit_price,
        OLD.estimated_amount_ccy, NEW.estimated_amount_ccy,
        OLD.price_status, NEW.price_status, v_reason);
    RETURN NEW;
END;
$function$
