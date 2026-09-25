CREATE OR REPLACE FUNCTION public.batch_freight_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【屏幕读取器】0.00 与「受限」不是同一件事:第一个是谎话。
    -- 白名单与 batch_processing_cost_base 逐字相同,理由也逐字相同 ——
    -- 【承重的那一格】allocate_processing_costs 的调用者【必然】读得到这里,于是
    -- 材料成本表达式里这一支【按构造】不可能是 NULL。一个 NULL 加数会让
    -- SUM 跳过整条投料腿(连 unit_price 一起),那比读到 0 更坏。
    -- ★ ROLE-1(2026-09-23):分摊的门从 module.processing.edit 换成 module.finance.edit,
    --   于是承重的是 finance.view 那一格(edit 蕴含 view —— set_role_permissions 的
    --   EDIT_REQUIRES_VIEW)。processing.edit 那一格原样留着:它不放宽任何东西
    --   (持它必持 processing.view),拿掉它是另一刀的事。fixture 163 的 D 臂钉的是这一格。
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
        THEN batch_freight_base_all(p_inbound_batch_id)
        ELSE NULL
    END;
$function$;