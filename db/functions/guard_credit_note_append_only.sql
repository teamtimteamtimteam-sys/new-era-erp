CREATE OR REPLACE FUNCTION public.guard_credit_note_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【自己报名,不靠外键顺带挡】(FIN-31)—— 一句外键约束名既没说是哪张单据,
    -- 也没说下一步该做什么。
    RAISE EXCEPTION 'CREDIT_NOTE_IMMUTABLE|%', TG_OP;
END;
$function$

;
