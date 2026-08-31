-- db/functions/inbound_batch_has_landed_cost.sql
-- CLEANUP-A(2026-08-31):「有没有价」是事实,不是价 —— 一条布尔,判据 module.inventory.view。
-- 存在的理由:上面那支现在会拒绝没有 data.view_prices 的读者,而 unpriced 一列
-- 本来就该给这种读者看。判据与那支的 NULL 条件逐字互补,漂开则 unpriced 说谎。

CREATE OR REPLACE FUNCTION public.inbound_batch_has_landed_cost(p_inbound_batch_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_has boolean;
BEGIN
    IF NOT has_permission('module.inventory.view'::text) THEN
        RAISE EXCEPTION 'LANDED_COST_FACT_PERMISSION_DENIED|%', 'module.inventory.view'
          USING HINT = '"这批货有没有价"是一条库存事实 —— 要有库存模块的查看权限。'
                       '它不透出金额,所以不要 data.view_prices。';
    END IF;

    -- 与 inbound_batch_landed_unit_cost 的 NULL 判据【逐字互补】:
    -- has_landed_cost = NOT (landed_unit_cost IS NULL)。两处若漂开,unpriced 就会说谎。
    SELECT NOT (ib.unit_price IS NULL
                AND batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id) = 0)
      INTO v_has
      FROM inbound_batches ib
     WHERE ib.id = p_inbound_batch_id;

    RETURN v_has;
END
$function$;

COMMENT ON FUNCTION public.inbound_batch_has_landed_cost(p_inbound_batch_id uuid) IS
    'CLEANUP-A:「这批进料有没有落地成本」—— 一条布尔事实,不透出金额,判据 module.inventory.view。存在的理由:inbound_batch_landed_unit_cost 现在会拒绝没有 data.view_prices 的读者,而 inbound_batch_valuation.unpriced 这一列本来就该给这种读者看(INV-VAL-1:"有没有价是事实,不是价")。判据与那支函数的 NULL 条件逐字互补,漂开则 unpriced 说谎。';
