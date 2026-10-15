-- db/functions/guard_equipment_direct_write.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q6,Tim):【设备的三张表不许绕过函数写】—— 关掉 EQP-2d 登记的"三张表没有 RPC"。
--   停机 · 保养维修 · 保养间隔此前经 PostgREST 直连 + RLS 写(INSERT / UPDATE 策略开在 module.processing.edit 上),
--   拒绝因此是约束名而不是业务码;本刀给它们五支函数 —— open_equipment_downtime · close_equipment_downtime ·
--   correct_equipment_downtime · record_equipment_maintenance · save_equipment_service_interval —— 按名拒,并拿掉直连的
--   INSERT 与 UPDATE 策略。作废停机照旧只经 void_equipment_downtime;资本化照旧只经 record_expense。
--   【为什么还要这一支】策略拿掉之后,直连 INSERT 撞的是一句没有名字的 RLS 违反,直连 UPDATE 是【零行、不报错】(SILENT-1 那一族)。
--   所以挂成【语句级 BEFORE】,零行也照样触发,按名拒 EQUIPMENT_THROUGH_FUNCTION_ONLY|表|动作。
--   挂法:equipment_downtime 与 equipment_service_intervals —— INSERT OR UPDATE(停机的 DELETE 早由 guard_downtime_write 按名拒;
--   间隔的 DELETE 策略刻意留着:删一条间隔 = 回到「未监控」,那是一个正当的决定,见那张表的注释);
--   equipment_maintenance —— INSERT OR UPDATE OR DELETE(干过的活删不掉;此前没有 DELETE 策略时那一句是一次静默的零行)。
--   属主路径(row_security_active = false:SECURITY DEFINER 的函数、迁移、种子、fixture 以 postgres 跑)一律放行。
--   【为什么是 INVOKER】要分出直连写与属主路径;理由与 guard_processing_direct_write 的抬头相同。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.guard_equipment_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'EQUIPMENT_THROUGH_FUNCTION_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
END;
$function$;
