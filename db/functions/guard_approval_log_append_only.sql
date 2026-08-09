CREATE OR REPLACE FUNCTION public.guard_approval_log_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 留痕被改写过,就不是留痕了。两种操作分开报名,免得排查时还要猜是哪一种。
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'APPROVAL_LOG_APPEND_ONLY|update|%', OLD.id;
    ELSE
        RAISE EXCEPTION 'APPROVAL_LOG_APPEND_ONLY|delete|%', OLD.id;
    END IF;
END;
$function$;