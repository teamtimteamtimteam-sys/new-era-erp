-- db/functions/inbound_batch_valuation_rows.sql
-- INV-VAL-1-fu6:inbound_batch_valuation 的取数体(视图属主权限替不了函数的 EXECUTE)。
-- CLEANUP-A:unpriced 一列改走 inbound_batch_has_landed_cost —— 只改了这一处。

CREATE OR REPLACE FUNCTION public.inbound_batch_valuation_rows()
 RETURNS TABLE(id uuid, code text, material_id uuid, supplier_id uuid, unit text, quantity numeric, remaining_qty numeric, arrival_date date, stage text, landed_unit_cost numeric, landed_value_base numeric, unpriced boolean, aging_days integer, aging_bucket text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_prices boolean;
BEGIN
    -- 【definer 必须自己问调用者是谁】—— 授权不是控制。
    PERFORM require_permission('module.inventory.view');
    v_prices := has_permission('data.view_prices');

    RETURN QUERY
    SELECT ib.id, ib.code, ib.material_id, ib.supplier_id, ib.unit,
           ib.quantity, ib.remaining_qty, ib.arrival_date, ib.stage,
           -- 价格遮蔽:没有 data.view_prices 的读者得 NULL,【不是 0】
           CASE WHEN v_prices THEN inbound_batch_landed_unit_cost(ib.id)
                ELSE NULL::numeric END,
           CASE WHEN v_prices
                THEN round(COALESCE(ib.remaining_qty * inbound_batch_landed_unit_cost(ib.id), 0), 2)
                ELSE NULL::numeric END,
           -- 【不遮蔽】有没有价是事实,不是价 —— CLEANUP-A 起走那条布尔事实,
           -- 因为价格函数现在会拒绝没有 data.view_prices 的读者。
           NOT inbound_batch_has_landed_cost(ib.id),
           (CURRENT_DATE - ib.arrival_date)::integer,
           aging_bucket((CURRENT_DATE - ib.arrival_date)::integer)
      FROM inbound_batches ib
     WHERE ib.deleted_at IS NULL;
END;
$function$;

COMMENT ON FUNCTION public.inbound_batch_valuation_rows() IS
    'INV-VAL-1-fu6:inbound_batch_valuation 的取数体。★存在的唯一理由:视图的属主权限【替不了函数的 EXECUTE】(aging_bucket 抬头记着这条规矩),而 inbound_batch_landed_unit_cost 刻意没有授给 authenticated —— 于是那张视图一被 SELECT 到计算列就 42501,/inventory 与进料钻取页在线上整页报错。SECURITY DEFINER 会改变 current_user,所以在这里调那支未授权的函数是过得去的;而它【不给那支函数授任何权限】,那一条排在开账前的权限清理里。本函数自己 require_permission、自己按 data.view_prices 遮蔽价格;unpriced 不遮蔽 —— 有没有价是事实,不是价。';
