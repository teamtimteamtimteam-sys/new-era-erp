CREATE OR REPLACE FUNCTION public.guard_shipment_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 发货单、发货行、送货单签发档共用这一条:只增不改。
    -- 【为什么没有"作废"】货发出去了就是发出去了 —— 2500 已经释放进 4000、
    -- 库存已经离开台账。改一张发货单等于把一件发生过的物理事件改写成另一件;
    -- 更正走【贷项凭证】(credit note,sales_records 表头停放的未来概念)。
    RAISE EXCEPTION 'SHIPMENT_IMMUTABLE|%', TG_OP;
END;
$function$

;
