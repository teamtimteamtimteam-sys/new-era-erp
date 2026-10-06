-- db/functions/issue_gateway_key.sql
-- MES-1(2026-10-06,MES-0 Q5 · §3.4;MES-1 Step 0 Q5,Tim):给一台网关发一把钥匙 —— 【密钥只在这一次返回值里出现】。
--   持 action.manage_devices;那台设备必须是一台没停用的网关;它已经有两把有效钥匙就按名拒(守卫:GATEWAY_KEY_TWO_ACTIVE)。
--   密钥 = 'ngk_' + 两个 gen_random_uuid() 去掉连字符(64 个十六进制字符,244 位随机;PostgreSQL 内建,不用 pgcrypto —— Q5,
--   线上 17.6)。存下的是 'ngk_' 之后的 8 个字符(前缀,页面认得出是哪一把)与 sha256(密钥) —— 密钥本身哪里都不存。
--   变更记录记下发放这件事(前缀、谁、何时);哈希被 never 规则遮住(Q20)。
--   返回 {key_id, prefix, secret}。页面把 secret 显示一次,然后它就没了:丢了就再发一把、撤旧的那把。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.issue_gateway_key(p_gateway_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_secret text;
    v_id     uuid;
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF p_gateway_id IS NULL THEN
        RAISE EXCEPTION 'GATEWAY_KEY_NOT_A_GATEWAY|?';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('ingest:' || p_gateway_id::text)::bigint);
    v_secret := 'ngk_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    INSERT INTO gateway_keys (gateway_id, key_prefix, key_hash, issued_by)
    VALUES (p_gateway_id, substr(v_secret, 5, 8), sha256(convert_to(v_secret, 'UTF8')), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('key_id', v_id, 'prefix', substr(v_secret, 5, 8), 'secret', v_secret);
END;
$function$;
