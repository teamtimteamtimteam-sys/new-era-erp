CREATE OR REPLACE FUNCTION public.guard_sales_record_movements_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 腿是台账的一部分,而台账只增不改。改一条腿指向别的流水,等于把一笔已经
    -- 发生的出库改记到另一批货上 —— 那与改销售记录本身同罪(SALE_IMMUTABLE)。
    RAISE EXCEPTION 'SALE_LEG_IMMUTABLE|%', TG_OP;
END;
$function$

;
