CREATE OR REPLACE FUNCTION public.guard_purchase_order_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 【自己报名,不靠外键顺带挡】(FIN-31 那一条)。此前拦住带明细采购单的是
    -- purchase_order_history 的外键,而那句报错既没说是哪张单、也没说规矩;
    -- 零明细的单子它更是完全不拦。撤销一张采购单走 cancel_purchase_order,
    -- 它留下 cancelled_at 与 cancel_reason。
    RAISE EXCEPTION 'PO_NO_HARD_DELETE|%', OLD.code;
END;
$function$;
