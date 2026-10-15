-- db/functions/guard_downtime_cause_class.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3):【一种停机原因被引用之后,它的类别冻住】。
--   MTBF / MTTR 读的是原因【此刻】的类别(downtime_causes.class)。若一种已经被停机引用的原因从 planned 改成 failure,
--   过去每一段那样的停机都会悄悄变成一次故障,已经报出去的 MTBF 跟着变 —— 而没有任何一行停机被改过。所以:
--   引用之后改类别按名拒(DOWNTIME_CAUSE_CLASS_LOCKED|<代号>|<已被几段停机引用>);名字、排序、停用、备注照改。
--   要换类别,就新加一种原因。删一种被引用的原因由停机表的外键挡着。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.guard_downtime_cause_class()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n integer;
BEGIN
    IF NEW.code IS DISTINCT FROM OLD.code OR NEW.class IS DISTINCT FROM OLD.class THEN
        SELECT count(*) INTO v_n FROM equipment_downtime d WHERE d.cause_code = OLD.code;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'DOWNTIME_CAUSE_CLASS_LOCKED|%|%', OLD.code, v_n;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;
