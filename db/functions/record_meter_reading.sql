-- db/functions/record_meter_reading.sql
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q20,Tim):【在设备页上手工记一条电表读数】—— action.confirm_capture(采集那条管子已经在用的码;
--   线上 admin · cto · warehouse)。判据全在 meter_reading_internal(记与更正共用)。
--   【为什么不经 submit_manual_capture】那条手工路要跑这一类的转换器,而 meter_reading 的转换器【没有建】—— 没有任何电表给过数据格式,
--   照着一个编出来的格式建就是 MES-3b Q25 / MES-4a Q14 说的那件事。照 MES-5a-1 记放电结果的先例:直接记,source = manual,
--   收件箱 / 草稿 / 现场数据那几列留空;将来接上设备,那几列已经在,不必改表。
--   返回 {id, device_code}。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE OR REPLACE FUNCTION public.record_meter_reading(p_device_id uuid, p_read_at timestamp with time zone, p_register_kwh numeric, p_register_reset boolean DEFAULT false, p_reset_reason text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id bigint;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    v_id := meter_reading_internal(p_device_id, p_read_at, p_register_kwh, p_register_reset, p_reset_reason, p_notes, false, NULL, NULL);
    RETURN jsonb_build_object('id', v_id, 'device_code', (SELECT d.code FROM devices d WHERE d.id = p_device_id));
END;
$function$
