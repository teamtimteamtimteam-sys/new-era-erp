CREATE OR REPLACE FUNCTION public.release_reservation(p_reservation_id uuid, p_qty numeric DEFAULT NULL::numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 释放一条预留是销售行为(撤回一个已经做出的承诺)—— module.sales.edit。
    -- ★ APR-5b:函数体搬进 release_reservation_internal(ship_order 部分发货要用它,而发货归仓库)。
    PERFORM require_permission('module.sales.edit');
    RETURN release_reservation_internal(p_reservation_id, p_qty, p_reason);
END;
$function$

;
