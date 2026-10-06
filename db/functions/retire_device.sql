-- db/functions/retire_device.sql
-- MES-1(2026-10-06):停用一台设备 —— 不删(收件箱、传输日志、钥匙都指着它),停用就是它的去处。
--   持 action.manage_devices;要写理由(DEVICE_RETIRE_REASON_REQUIRED);已经停用的按名拒(DEVICE_RETIRED)。
--   停用一台网关,同一笔事务里把它还有效的钥匙一并撤掉(理由照抄)—— 一台停用的网关本来就一律被拒(retired_gateway),
--   撤掉钥匙是让设备页上不再挂着"有效"两个字。它带着的设备不动(它们的消息本来就要经它进来)。
--   停用之后那一行冻住(守卫)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.retire_device(p_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row devices%ROWTYPE;
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DEVICE_RETIRE_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_row FROM devices WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DEVICE_NOT_FOUND';
    END IF;
    IF v_row.retired_at IS NOT NULL THEN
        RAISE EXCEPTION 'DEVICE_RETIRED|%', v_row.code;
    END IF;
    IF v_row.kind = 'gateway' THEN
        UPDATE gateway_keys
           SET revoked_at = now(), revoked_by = auth.uid(), revoke_reason = btrim(p_reason)
         WHERE gateway_id = p_id AND revoked_at IS NULL;
    END IF;
    UPDATE devices
       SET retired_at = now(), retired_by = auth.uid(), retire_reason = btrim(p_reason), updated_by = auth.uid()
     WHERE id = p_id;
END;
$function$;
