CREATE OR REPLACE FUNCTION public.guard_sales_order_line_confirmed_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
BEGIN
    SELECT * INTO v_order FROM sales_orders
     WHERE id = COALESCE(NEW.sales_order_id, OLD.sales_order_id);

    IF v_order.status = 'draft' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|lines|%', v_order.code;
END;
$function$

;
