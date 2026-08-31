-- db/functions/inbound_batch_valuation_rows.sql
-- INV-VAL-1-fu6:inbound_batch_valuation 的取数体。
--
-- ★【存在的唯一理由:视图的属主权限【替不了函数的 EXECUTE】】★
--   inbound_batch_landed_unit_cost 刻意没有授给 authenticated(它是 definer、
--   直接读基表 unit_price、绕过价格遮蔽、且自己不判权限)。
--   而 security_invoker = off 【不改变 current_user】—— 所以视图体内那次调用
--   仍按调用者判,真实用户一 SELECT 到计算列就 42501,/inventory 整页红框。
--   **SECURITY DEFINER 才改变 current_user**,所以取数必须发生在这里。
--   它【不给那支成本函数授任何权限】—— 那一条排在开账前的权限清理里。
--
-- 【自己 require_permission + 自己遮蔽价格】授权不是控制。
-- unpriced 不遮蔽:"有没有价"是事实,不是价。
--
-- db/fixtures/173 以【真实用户身份】(SET LOCAL ROLE authenticated)钉住这四件事,
-- 并用"收掉本函数的 EXECUTE → 视图当场变红"证明断言不是空转。
--
-- NOTE: introduced by db/migrations/2026-08-31-invval1-fu6-a-view-owner-does-not-lend-you-execute.sql.

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
           -- 【不遮蔽】有没有价是事实,不是价
           (inbound_batch_landed_unit_cost(ib.id) IS NULL),
           (CURRENT_DATE - ib.arrival_date)::integer,
           aging_bucket((CURRENT_DATE - ib.arrival_date)::integer)
      FROM inbound_batches ib
     WHERE ib.deleted_at IS NULL;
END;
$function$
;
