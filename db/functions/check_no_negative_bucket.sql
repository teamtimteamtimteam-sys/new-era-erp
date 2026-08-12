CREATE OR REPLACE FUNCTION public.check_no_negative_bucket()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_qty numeric;
    v_code text;
BEGIN
    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_qty
    FROM inventory_movements m
    WHERE m.stock_status = NEW.stock_status
      AND m.inbound_batch_id IS NOT DISTINCT FROM NEW.inbound_batch_id
      AND m.output_batch_id  IS NOT DISTINCT FROM NEW.output_batch_id
      AND m.location_id      IS NOT DISTINCT FROM NEW.location_id;

    IF v_qty < 0 THEN
        SELECT COALESCE(ib.code, ob.code) INTO v_code
        FROM (SELECT 1) x
        LEFT JOIN inbound_batches ib ON ib.id = NEW.inbound_batch_id
        LEFT JOIN output_batches  ob ON ob.id = NEW.output_batch_id;
        RAISE EXCEPTION 'STK_NEGATIVE_BUCKET|%|%|%',
            COALESCE(v_code, '?'), NEW.stock_status, v_qty;
    END IF;
    RETURN NULL;
END;
$function$

;
