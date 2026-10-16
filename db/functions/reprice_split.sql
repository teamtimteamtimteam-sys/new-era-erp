-- db/functions/reprice_split.sql
-- 改价的拆账算术 —— reprice_inbound_batch 与 preview_reprice_inbound_batch 共用这一份(AGENTS.md「一份实现,两个调用者」)。
-- 价差 delta = round(整批数量 × (新价 − 旧价), 2);在库份额按 剩余 ÷ 数量 进 1200,其余是已离开库存的份额。
-- ★ MES-7a-2(2026-10-16,MES-7a Step 0 Q13,Tim):【它认得出给保养的那一份】—— 多一个入参 p_maintenance_qty(这一批出给保养、减去退回的
--   数量:inbound_batch_maintenance_net_qty 读 maintenance_issue / maintenance_return 两种流水)。已离开库存的份额于是拆成两块:
--   出给保养的那一份进 6800 Repairs & Maintenance(maintenance_share_usd),其余(加工消耗、销售、注销……)照旧进 5000(cost_share_usd)。
--   签名换了(四个入参 → 五个),旧的那一支在迁移里 DROP —— 两支并存就是一次镜像看不见的重载(FIN-21)。
--   ★ 取整:在库份额与保养份额各自 round 到分;当这两块已经占满整批(没有别的消耗)时,保养份额取 delta − 在库份额,
--     于是 cost_share 恰好是 0,不会因为两次取整变成 −0.01。
-- 不带 SET search_path:纯算术,IMMUTABLE(journal_activity_lines 的注释提到它同样不带)。

CREATE OR REPLACE FUNCTION public.reprice_split(p_quantity numeric, p_remaining numeric, p_old_price numeric, p_new_price numeric, p_maintenance_qty numeric)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- ratio 用未取整的值参与乘法(与历来的入账口径一致),仅在输出时取到 4 位
    SELECT jsonb_build_object(
        'delta_usd', d.delta,
        'in_stock_ratio', round(d.ratio, 4),
        'inventory_share_usd', d.inv,
        'maintenance_ratio', round(d.mratio, 4),
        'maintenance_share_usd', d.mnt,
        'cost_share_usd', round(d.delta - d.inv - d.mnt, 2)
    )
    FROM (
        SELECT delta, ratio, mratio, round(delta * ratio, 2) AS inv,
               CASE WHEN mratio = 0 THEN 0
                    WHEN ratio + mratio >= 1 THEN delta - round(delta * ratio, 2)
                    ELSE round(delta * mratio, 2) END AS mnt
        FROM (
            SELECT delta, ratio, LEAST(1 - ratio, mr) AS mratio
            FROM (
                SELECT round(p_quantity * (p_new_price - COALESCE(p_old_price, 0)), 2) AS delta,
                       CASE WHEN p_quantity = 0 THEN 1
                            ELSE LEAST(1, GREATEST(0, p_remaining / p_quantity)) END AS ratio,
                       CASE WHEN p_quantity = 0 THEN 0
                            ELSE LEAST(1, GREATEST(0, COALESCE(p_maintenance_qty, 0) / p_quantity)) END AS mr
            ) x0
        ) x
    ) d;
$function$;
