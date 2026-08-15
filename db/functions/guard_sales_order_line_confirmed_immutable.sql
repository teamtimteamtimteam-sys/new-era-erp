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

    -- SO-1b:【改单是这一堵墙上唯一的门】—— 而门后还有三条下限
    -- (trg_sales_order_lines_floors,按名字排在本守卫【之后】跑,所以直连的
    -- 那条路先撞上"确认之后行是冻的",而不是先撞上下限)。
    -- 【标记是 amend 专用的,不是 so_status_ctx】后者会让整行放行,包括状态列。
    IF current_setting('evoltrya.so_amend_ctx', true) = '1' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|lines|%', v_order.code;
END;
$function$

;
