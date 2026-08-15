CREATE OR REPLACE FUNCTION public.guard_quote_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 自己报名,不靠外键顺带挡(FIN-31)
    RAISE EXCEPTION 'QT_HISTORY_IMMUTABLE|%', TG_OP;
END;
$function$

;
