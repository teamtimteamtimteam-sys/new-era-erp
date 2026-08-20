CREATE OR REPLACE FUNCTION public.guard_shipment_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 删除:三张表都永不允许。
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SHIPMENT_IMMUTABLE|%', TG_OP;
    END IF;

    -- 【唯一的例外:shipments 上只有 container_id 变了】
    IF TG_TABLE_NAME = 'shipments' THEN
        IF (NEW.id, NEW.code, NEW.sales_order_id, NEW.ship_date, NEW.notes,
            NEW.created_at, NEW.created_by)
           IS NOT DISTINCT FROM
           (OLD.id, OLD.code, OLD.sales_order_id, OLD.ship_date, OLD.notes,
            OLD.created_at, OLD.created_by)
        THEN
            RETURN NEW;   -- 只动了 container_id(或什么都没动)
        END IF;
    END IF;

    -- 发货单、发货行、送货单签发档共用这一条:只增不改。
    -- 【为什么没有"作废"】货发出去了就是发出去了 —— 2500 已经释放进 4000、
    -- 库存已经离开台账。改一张发货单等于把一件发生过的物理事件改写成另一件;
    -- 更正走【贷项凭证】。
    RAISE EXCEPTION 'SHIPMENT_IMMUTABLE|%', TG_OP;
END;
$function$

