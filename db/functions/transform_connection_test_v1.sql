-- db/functions/transform_connection_test_v1.sql
-- MES-1(2026-10-06,MES-1 Step 0 Q3 · Q12,Tim):【connection_test 这一类的转换器,第一版】—— 采集层唯一一支 MES-1 就有的转换器。
--   它证明分派、成功、失败、重试与丢弃,也让厂商在任何业务类存在之前就能从头到尾试一次(docs/integration/gateway-interface.md)。
--   payload 必须是 {"text": "<1–200 个字符>"};否则按名拒 CONNECTION_TEST_TEXT_REQUIRED —— 那一行进 failed,看得见。
--   成功的结果是 {"text": <去掉首尾空白的那段字>};它不落到任何正式记录(这一类没有目标)。
--   【只读它的参数】IMMUTABLE,不碰任何表 —— 一支转换器只做验证与规整;落正式记录是 MES-2 起的事。
--   不是 SECURITY DEFINER;EXECUTE 从 authenticated 收回(只经 ingest_transform_row 调)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.transform_connection_test_v1(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_text text;
BEGIN
    IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR jsonb_typeof(p_payload -> 'text') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'CONNECTION_TEST_TEXT_REQUIRED';
    END IF;
    v_text := btrim(p_payload ->> 'text');
    IF char_length(v_text) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'CONNECTION_TEST_TEXT_REQUIRED';
    END IF;
    RETURN jsonb_build_object('text', v_text);
END;
$function$;
