-- db/functions/guard_maintenance_movement.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12,Tim):【备件的出与退只经那两支函数】—— inventory_movements BEFORE INSERT(行级),
--   只对 maintenance_issue / maintenance_return 两种类型触发(触发器上的 WHEN)。issue_spare_parts / return_spare_parts 在事务里设
--   evoltrya.part_issue_ctx(写完即清);没有它 = 别的写法(另一支属主函数、一张盘点、一次转移、一句手写的 INSERT)想写这两种类型,
--   按名拒 MAINTENANCE_MOVEMENT_THROUGH_FUNCTION_ONLY|<类型>。于是每一行这种流水都恰好对应 maintenance_part_issues 的一行,
--   而那一行带着保养记录、理由与分录 —— 流水自己不带这些指针。
--   【为什么是 INVOKER】它只读一个会话设置,不读任何表(guard_movement_direct_insert 同形)。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.guard_maintenance_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF COALESCE(current_setting('evoltrya.part_issue_ctx', true), '') = '' THEN
        RAISE EXCEPTION 'MAINTENANCE_MOVEMENT_THROUGH_FUNCTION_ONLY|%', NEW.movement_type;
    END IF;
    RETURN NEW;
END;
$function$;
