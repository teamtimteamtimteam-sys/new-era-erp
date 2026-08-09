CREATE OR REPLACE FUNCTION public.guard_customer_credit_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 留痕被改写过就不是留痕了。自己报名(FIN-31)。
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'CREDIT_HISTORY_APPEND_ONLY|update|%', OLD.id;
    ELSE
        RAISE EXCEPTION 'CREDIT_HISTORY_APPEND_ONLY|delete|%', OLD.id;
    END IF;
END;
$function$;