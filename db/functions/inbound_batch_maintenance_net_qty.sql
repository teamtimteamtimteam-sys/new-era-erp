-- db/functions/inbound_batch_maintenance_net_qty.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q13,Tim):【一批里有多少已经出给了保养(减去退回的)】—— maintenance_issue 与 maintenance_return
--   两种流水之和的相反数。reprice_inbound_batch 与 preview_reprice_inbound_batch 把它递给 reprice_split,于是改价时已出给保养那一份的
--   价差进 6800、不进 5000(一份算术,两个调用者);inventory_control_reconciliation 用它把 M3 / M4 两条机制项里的"已被消耗"限在加工消耗上
--   (出给保养的那一份在出库那一刻就按落地单价解除了 1200,不是一份搁浅的资本化)。
--   不授给 authenticated —— 只在那几支 DEFINER 里被调用(它不问码,只回一个数量)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.inbound_batch_maintenance_net_qty(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(- sum(m.qty_delta), 0)
      FROM inventory_movements m
     WHERE m.inbound_batch_id = p_inbound_batch_id
       AND m.movement_type IN ('maintenance_issue', 'maintenance_return');
$function$;
