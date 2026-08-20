CREATE OR REPLACE FUNCTION public.attach_shipment_to_container(p_shipment_id uuid, p_container_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ship text; v_ctr text;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT code INTO v_ship FROM shipments WHERE id = p_shipment_id FOR UPDATE;
    IF v_ship IS NULL THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_FOUND|%', COALESCE(p_shipment_id::text, '?');
    END IF;
    -- 【软删的箱子不能再装货】—— 它已经被人按名注销过了
    SELECT code INTO v_ctr FROM containers
     WHERE id = p_container_id AND deleted_at IS NULL;
    IF v_ctr IS NULL THEN
        RAISE EXCEPTION 'CONTAINER_NOT_FOUND|%', COALESCE(p_container_id::text, '?')
          USING HINT = '这个箱子不存在,或者已经被注销了';
    END IF;

    UPDATE shipments SET container_id = p_container_id WHERE id = p_shipment_id;
    RETURN jsonb_build_object('shipment', v_ship, 'container', v_ctr);
END;
$function$

