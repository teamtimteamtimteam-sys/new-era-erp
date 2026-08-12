CREATE OR REPLACE FUNCTION public.derived_stock_qty(p_inbound_batch_id uuid, p_output_batch_id uuid, p_location_id uuid, p_stock_status text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_qty numeric;
BEGIN
    -- 看得见库存分布 = 看得见库存模块。拒绝【点名】,不伪装成 0。
    PERFORM require_permission('module.inventory.view');

    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_qty
    FROM inventory_movements m
    WHERE m.stock_status = p_stock_status
      AND m.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
      AND m.output_batch_id  IS NOT DISTINCT FROM p_output_batch_id
      AND m.location_id      IS NOT DISTINCT FROM p_location_id;

    RETURN v_qty;
END;
$function$

;
