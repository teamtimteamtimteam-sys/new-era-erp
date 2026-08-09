CREATE OR REPLACE FUNCTION public.customer_ar_exposure_visible(p_customer_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN has_permission('module.customers.view')
                THEN customer_ar_exposure_base(p_customer_id) END;
$function$;