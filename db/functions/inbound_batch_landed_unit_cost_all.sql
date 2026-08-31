-- db/functions/inbound_batch_landed_unit_cost_all.sql
-- CLEANUP-A fu1(2026-08-31):落地单位成本的【过账】原语 —— 无判据,刻意的。
-- 账上的金额不许取决于按按钮的人有什么读权限。与 batch_freight_base_all /
-- batch_processing_cost_base_all 同一条理由、同一个后缀。不授给 authenticated。

CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost_all(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【无判据,这是刻意的】它算的是要过账的钱,而账上的金额不许取决于
    -- 按按钮的人有什么读权限(emit_batch_writeoff_movement 的抬头写着同一句)。
    -- 与 batch_freight_base_all / batch_processing_cost_base_all 同一条理由、同一个后缀。
    --
    -- 算术与 CLEANUP-A 之前的 inbound_batch_landed_unit_cost 【逐字相同】——
    -- PROC-COST-2 R1「注销与盘点必须永远给同一个答案」靠的就是这一份实现。
    --
    -- 【什么时候是 NULL】采购价没定过【而且】两项资本化都为零 —— 那是一批
    -- 真正"没有金额"的货,调用方据此只出量、不入账。
    SELECT CASE
        WHEN ib.unit_price IS NULL
         AND batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id) = 0
        THEN NULL
        ELSE COALESCE(ib.unit_price, 0)
             + CASE WHEN ib.quantity > 0
                    THEN (batch_freight_base_all(ib.id)
                          + batch_processing_cost_base_all(ib.id)) / ib.quantity
                    ELSE 0 END
    END
    FROM inbound_batches ib
    WHERE ib.id = p_inbound_batch_id;
$function$;

COMMENT ON FUNCTION public.inbound_batch_landed_unit_cost_all(p_inbound_batch_id uuid) IS
    'CLEANUP-A fu1:落地单位成本的【过账】原语 —— 无判据,刻意的。账上的金额不许取决于按按钮的人有什么读权限(emit_batch_writeoff_movement 的抬头写着同一句;一个只有 inbound.edit 的仓管按下注销时,带判据的读取器会让这笔钱静默变 0)。与 batch_freight_base_all / batch_processing_cost_base_all 同一条理由、同一个后缀。四个机器调用方:注销触发器、post_stocktake、inventory_control_reconciliation、inventory_valuation_snapshot。算术与带判据的那一支逐字相同 —— PROC-COST-2 R1 「注销与盘点必须永远给同一个答案」靠的就是这一份实现。不授给 authenticated。';
