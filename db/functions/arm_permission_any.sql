CREATE OR REPLACE FUNCTION public.arm_permission_any(p_item_type text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN p_item_type = 'margin_cost_not_allocated'
                THEN ARRAY['module.finance.view', 'module.processing.view']
           END;
$function$;