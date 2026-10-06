-- db/functions/transform_weighing_v1.sql
-- MES-2(2026-10-06,规格 §6.4;MES-0 §3.5;MES-2 Step 0 Q7,Tim):称重这一类的【转换器】—— 第一支落得出业务记录的转换器。
--   payload 只能是 {"weight_kg": <数 > 0>},别的什么都没有(Q7):单位在网关那头换算成公斤;毛重 / 皮重 / 净重与挂哪一张地磅单
--   是工位上的人在确认时选的,不是秤说的。对象以外、多一个键 → WEIGHING_PAYLOAD_INVALID;weight_kg 不是数或不 > 0 →
--   WEIGHING_WEIGHT_INVALID。返回 {"weight_kg": <数>}。
--   IMMUTABLE、只吃 payload(MES-1 的决定 7):它读不到任何表、写不了任何表。确认时改过的值也经它再验一次(同一支验证器,两个调用方)。
--   【内层】EXECUTE 从 authenticated 收回;分派器与确认那几支以属主身份按名字调它。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.transform_weighing_v1(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kg numeric;
BEGIN
    IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k <> 'weight_kg') THEN
        RAISE EXCEPTION 'WEIGHING_PAYLOAD_INVALID';
    END IF;
    IF jsonb_typeof(p_payload -> 'weight_kg') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'WEIGHING_WEIGHT_INVALID';
    END IF;
    v_kg := (p_payload ->> 'weight_kg')::numeric;
    IF v_kg <= 0 THEN
        RAISE EXCEPTION 'WEIGHING_WEIGHT_INVALID';
    END IF;
    RETURN jsonb_build_object('weight_kg', v_kg);
END;
$function$;
