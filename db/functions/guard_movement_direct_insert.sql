-- db/functions/guard_movement_direct_insert.sql
-- MES-3a(2026-10-06,MES-3a Step 0 Q3,Tim):库存流水【不许从会话里直连插】—— MOVEMENTS_THROUGH_FUNCTION_ONLY。
--   此前 inventory_movements 上有一条 INSERT 策略(module.inventory.edit):一对手搭的 transfer_out / transfer_in 过得了台账
--   不变式,却绕过每一道落闸(货位分类、隔离)。策略已拿掉;这一支让直连插【按名】拒,而不是一句没名字的 RLS 违规。
--   属主路径(row_security_active = 假:SECURITY DEFINER 的收货、转移、暂扣、发货、加工、盘点,以及批次上的触发器)放行。
--   【为什么是 INVOKER】row_security_active 必须反映【调用者】的视角(guard_processing_direct_write 同一个理由)。
--   行级 BEFORE INSERT:RLS 的 WITH CHECK 在 BEFORE 行触发器之后才判,所以这一句先到。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.guard_movement_direct_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'MOVEMENTS_THROUGH_FUNCTION_ONLY|%', NEW.movement_type;
    END IF;
    RETURN NEW;
END;
$function$;
