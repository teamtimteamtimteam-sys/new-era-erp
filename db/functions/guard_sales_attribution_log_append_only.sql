CREATE OR REPLACE FUNCTION public.guard_sales_attribution_log_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 能被改写的留痕不是留痕。自己报名(FIN-31)。
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'SALES_ATTRIBUTION_APPEND_ONLY|update|%', OLD.id;
    ELSE
        RAISE EXCEPTION 'SALES_ATTRIBUTION_APPEND_ONLY|delete|%', OLD.id;
    END IF;
END;
$function$;