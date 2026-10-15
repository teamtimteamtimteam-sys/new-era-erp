CREATE OR REPLACE FUNCTION public.arm_permission_any(p_item_type text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN p_item_type = 'margin_cost_not_allocated'
                THEN ARRAY['module.finance.view', 'module.processing.view']
                -- MES-6b-1:暂扣的判据(batch_quality_hold)以读者身份读不合格报告与产出批 —— 读者要持产出查看码,才不会少看一行
                WHEN p_item_type = 'quality_hold_reserved'
                THEN ARRAY['module.output.view']
           END;
$function$;