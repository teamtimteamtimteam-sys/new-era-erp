CREATE OR REPLACE FUNCTION public.guard_sales_order_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'SO_HISTORY_IMMUTABLE';
END;
$function$

;
