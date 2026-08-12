CREATE OR REPLACE FUNCTION public.resolve_receipt_location(p_location_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_active boolean;
BEGIN
    -- 不选就是不选 —— "未指定库位"是一等状态(LOC-1/STK-1),不是缺失。
    IF p_location_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT code, is_active INTO v_code, v_active
    FROM storage_locations WHERE id = p_location_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'IOD_RECEIPT_LOCATION_UNKNOWN';
    END IF;
    -- 停用的库位不该再收货(LOC-1 的停用语义:新单据不再提供它)
    IF NOT v_active THEN
        RAISE EXCEPTION 'IOD_RECEIPT_LOCATION_INACTIVE|%', v_code;
    END IF;

    RETURN p_location_id;
END;
$function$

;
