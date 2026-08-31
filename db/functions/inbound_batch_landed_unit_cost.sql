CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【R1 的算术,一份实现,两个调用者】注销触发器与 post_stocktake 各自
    -- 抄一遍就是两次漂移机会 —— 而它们必须永远对"这批货值多少钱"给同一个答案,
    -- 那正是 R1 要求两者【一起】改的理由。
    --
    -- 【分母是 quantity】与 allocate_processing_costs 材料成本表达式逐字相同,
    -- 于是消耗与注销互补、净得零。为什么不是 basis_qty:见本迁移抬头第二节。
    --
    -- 【读的是 _all 那一对,不是带判据的那一对】计值不许取决于谁按的按钮 ——
    -- 见抬头第四节。COALESCE(NULL, 0) 在这里会让缺陷无声复发。
    --
    -- 【什么时候是 NULL】采购价没定过【而且】两项资本化都为零 —— 那是一批
    -- 真正"没有金额"的货,调用方据此只出量、不入账(既有行为,一个字没松)。
    -- 反过来:没定过价【但身上挂着加工成本】的批次**必须**入账 ——
    -- 那笔钱确实进过 1200,不放出来就是本刀正在修的那件事。
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