CREATE OR REPLACE FUNCTION public.batch_processing_cost_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【屏幕读取器】PROC-COST-1 fu2 立的这条,本刀只把算术抽到
    -- batch_processing_cost_base_all 去 —— 行为一个字节没变,
    -- 变的是"算术"与"受众"从此各有一份定义,而计值路径读的是前者。
    -- ★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q5):【它是到岸成本的一部分,所以先问
    --   data.view_prices】。此前任何持 module.inbound.view 的人都读到真数,而仓库 4a 起又看得见收货
    --   单价 —— 单价 + (运费 + 加工费) / 数量 = 到岸单位成本(ROLE1B4A-LANDED-COST-STOCKTAKE-EXCEPTION)。
    --   不持它的人读到 NULL(不是 0),页面画「受限」。分摊(allocate_processing_costs)从本刀起读
    --   _all,不再靠调用者碰巧看得见 —— 所以 NULL 毒化求和那件事(fixture 163 D)不再挂在这里。
    SELECT CASE
        WHEN has_permission('data.view_prices')
         AND (has_permission('module.inbound.view')
          OR has_permission('module.finance.view')
          OR has_permission('module.processing.view')
          OR has_permission('module.processing.edit'))
        THEN batch_processing_cost_base_all(p_inbound_batch_id)
        ELSE NULL
    END;
$function$;