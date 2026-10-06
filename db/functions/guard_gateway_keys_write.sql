-- db/functions/guard_gateway_keys_write.sql
-- MES-1(2026-10-06,MES-0 Q5):网关钥匙的守卫。
--   ① 插入:那台设备必须是一台没停用的网关(GATEWAY_KEY_NOT_A_GATEWAY · GATEWAY_KEY_GATEWAY_RETIRED);
--      同一台网关已经有两把有效钥匙就拒第三把(GATEWAY_KEY_TWO_ACTIVE)—— 两把才能不停线地轮换,三把没有理由。
--   ② 更新:只许【撤销】,而且只撤一次 —— 撤销的三列从空到有;其余每一列(含哈希)一个字都不改
--      (GATEWAY_KEY_ONLY_REVOKE · GATEWAY_KEY_ALREADY_REVOKED)。撤了的钥匙不能复活。
--   ③ DELETE 一律拒(GATEWAY_KEY_NEVER_DELETED),语句级 —— 零行也触发。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.guard_gateway_keys_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind    text;
    v_retired timestamptz;
    v_code    text;
    v_n       integer;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'GATEWAY_KEY_NEVER_DELETED';
    END IF;
    IF TG_OP = 'INSERT' THEN
        SELECT d.kind, d.retired_at, d.code INTO v_kind, v_retired, v_code FROM devices d WHERE d.id = NEW.gateway_id;
        IF v_kind IS DISTINCT FROM 'gateway' THEN
            RAISE EXCEPTION 'GATEWAY_KEY_NOT_A_GATEWAY|%', COALESCE(v_code, '?');
        END IF;
        IF v_retired IS NOT NULL THEN
            RAISE EXCEPTION 'GATEWAY_KEY_GATEWAY_RETIRED|%', v_code;
        END IF;
        IF NEW.revoked_at IS NOT NULL THEN
            RAISE EXCEPTION 'GATEWAY_KEY_ONLY_REVOKE';
        END IF;
        SELECT count(*) INTO v_n FROM gateway_keys k WHERE k.gateway_id = NEW.gateway_id AND k.revoked_at IS NULL;
        IF v_n >= 2 THEN
            RAISE EXCEPTION 'GATEWAY_KEY_TWO_ACTIVE|%', v_code;
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.revoked_at IS NOT NULL THEN
        RAISE EXCEPTION 'GATEWAY_KEY_ALREADY_REVOKED|%', OLD.key_prefix;
    END IF;
    IF (to_jsonb(NEW) - 'revoked_at' - 'revoked_by' - 'revoke_reason')
       IS DISTINCT FROM (to_jsonb(OLD) - 'revoked_at' - 'revoked_by' - 'revoke_reason') THEN
        RAISE EXCEPTION 'GATEWAY_KEY_ONLY_REVOKE';
    END IF;
    RETURN NEW;
END;
$function$;
