CREATE OR REPLACE FUNCTION public.batch_processing_cost_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【屏幕读取器】PROC-COST-1 fu2 立的这条,本刀只把算术抽到
    -- batch_processing_cost_base_all 去 —— 行为一个字节没变,
    -- 变的是"算术"与"受众"从此各有一份定义,而计值路径读的是前者。
    SELECT CASE
        WHEN has_permission('module.inbound.view')
          OR has_permission('module.finance.view')
          OR has_permission('module.processing.view')
          OR has_permission('module.processing.edit')
        THEN batch_processing_cost_base_all(p_inbound_batch_id)
        ELSE NULL
    END;
$function$;