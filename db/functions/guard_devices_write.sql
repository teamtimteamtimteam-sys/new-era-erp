-- db/functions/guard_devices_write.sql
-- MES-1(2026-10-06):设备登记的守卫。
--   ① DELETE 一律拒(DEVICE_NEVER_DELETED)—— 收件箱、传输日志与网关钥匙指着它;一台不用了的设备的去处是停用。
--      挂在【语句级】:没有 DELETE 策略时 authenticated 的 DELETE 在 RLS 那里就是零行,行级触发器不会醒(U1-B 的那一课)。
--   ② 编号与种类定下就不动(DEVICE_CODE_FIXED · DEVICE_KIND_FIXED)—— 一台网关的钥匙、一台秤送来的消息都按它们认。
--   ③ 停用之后冻住(DEVICE_RETIRED|<编号>)。停用本身那一次 UPDATE(OLD.retired_at 为空)照常过。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.guard_devices_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'DEVICE_NEVER_DELETED';
    END IF;
    IF OLD.retired_at IS NOT NULL THEN
        RAISE EXCEPTION 'DEVICE_RETIRED|%', OLD.code;
    END IF;
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'DEVICE_CODE_FIXED|%', OLD.code;
    END IF;
    IF NEW.kind IS DISTINCT FROM OLD.kind THEN
        RAISE EXCEPTION 'DEVICE_KIND_FIXED|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;
