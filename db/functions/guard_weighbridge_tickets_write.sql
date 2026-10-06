-- db/functions/guard_weighbridge_tickets_write.sql
-- MES-2(2026-10-06,MES-0 Q19;MES-2 Step 0 Q16):地磅单的守卫。
--   ① DELETE / TRUNCATE 一律拒(TICKET_NEVER_DELETED),语句级 —— 一张不要了的单的去处是作废(要理由、而且没有分出去的份)。
--   ② 作废之后冻住(TICKET_VOIDED|<编号>)。
--   ③ 编号、方向、建单人与时刻定下就不动(TICKET_FIELD_FIXED|<编号>):方向决定第一磅是毛重还是皮重(Q16),
--      改了它,已经落下的那一磅的角色就说错了。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.guard_weighbridge_tickets_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'TICKET_NEVER_DELETED';
    END IF;
    IF OLD.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_VOIDED|%', OLD.code;
    END IF;
    IF NEW.code IS DISTINCT FROM OLD.code OR NEW.direction IS DISTINCT FROM OLD.direction
       OR NEW.created_at IS DISTINCT FROM OLD.created_at OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'TICKET_FIELD_FIXED|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;
