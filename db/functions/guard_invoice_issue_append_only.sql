CREATE OR REPLACE FUNCTION public.guard_invoice_issue_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【自己报名,不靠外键顺带挡】(FIN-31)—— 一句约束名既没说是哪张单据,
    -- 也没说下一步该做什么。客户手里那一份是某个具体版本:改它或删它,
    -- 就是把"当时发出去的是什么"这个问题变成没有答案。
    RAISE EXCEPTION 'INVOICE_ISSUE_IMMUTABLE|%', TG_OP;
END;
$function$

;
