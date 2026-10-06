-- db/functions/revoke_gateway_key.sql
-- MES-1(2026-10-06,MES-0 Q5 · §3.4):撤一把网关钥匙 —— 下一次调用就生效(ingest_submit 每一次都现查)。
--   持 action.manage_devices;要写理由(GATEWAY_KEY_REVOKE_REASON_REQUIRED);撤过的再撤按名拒(守卫:GATEWAY_KEY_ALREADY_REVOKED)。
--   撤一台网关的钥匙碰不到任何别的网关(钥匙按网关分)。轮换:发第二把 → 网关换上 → 撤第一把,线不停。
--   零行不许报成功:钥匙不存在就按名拒(GATEWAY_KEY_NOT_FOUND)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.revoke_gateway_key(p_key_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'GATEWAY_KEY_REVOKE_REASON_REQUIRED';
    END IF;
    UPDATE gateway_keys
       SET revoked_at = now(), revoked_by = auth.uid(), revoke_reason = btrim(p_reason)
     WHERE id = p_key_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GATEWAY_KEY_NOT_FOUND';
    END IF;
END;
$function$;
