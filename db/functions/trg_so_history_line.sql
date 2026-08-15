CREATE OR REPLACE FUNCTION public.trg_so_history_line()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reason text := NULLIF(current_setting('evoltrya.so_amend_reason', true), '');
BEGIN
    -- 见表头那一支:标记不在就不写。【建单的那一批行因此不记】—— 否则每张新单
    -- 都会先长出一份"全是新增"的历史,把真正的修改埋掉。建单本身有 'created' 那一行。
    IF current_setting('evoltrya.so_amend_ctx', true) IS DISTINCT FROM '1' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    IF TG_OP = 'INSERT' THEN
        INSERT INTO sales_order_history (sales_order_id, sales_order_line_id, line_no,
            change_type, new_quantity, new_unit_price, amend_reason)
        VALUES (NEW.sales_order_id, NEW.id, NEW.line_no, 'line_add',
            NEW.quantity, NEW.unit_price, v_reason);
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO sales_order_history (sales_order_id, sales_order_line_id, line_no,
            change_type, old_quantity, old_unit_price, amend_reason)
        VALUES (OLD.sales_order_id, OLD.id, OLD.line_no, 'line_remove',
            OLD.quantity, OLD.unit_price, v_reason);
        RETURN OLD;
    END IF;

    IF NEW.quantity IS NOT DISTINCT FROM OLD.quantity
       AND NEW.unit_price IS NOT DISTINCT FROM OLD.unit_price THEN
        RETURN NEW;
    END IF;
    INSERT INTO sales_order_history (sales_order_id, sales_order_line_id, line_no,
        change_type, old_quantity, new_quantity, old_unit_price, new_unit_price, amend_reason)
    VALUES (NEW.sales_order_id, NEW.id, NEW.line_no, 'line_update',
        OLD.quantity, NEW.quantity, OLD.unit_price, NEW.unit_price, v_reason);
    RETURN NEW;
END;
$function$

;
