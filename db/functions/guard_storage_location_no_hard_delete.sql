CREATE OR REPLACE FUNCTION public.guard_storage_location_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 停用(UPDATE is_active=false)才是这张表的下架语义:它保留库位的身份,
    -- 让历史流水指着的那一行继续说得出自己是谁。硬删两件都不做。
    -- 【为什么要具名】此前"删不掉"是 inventory_movements 的外键顺手挡下来的:
    -- 一条靠副作用成立的规则,读代码的人看不见,撞上的人只看到一个 23503。
    RAISE EXCEPTION 'LOCATION_NO_HARD_DELETE|%', OLD.code;
END;
$function$

;
