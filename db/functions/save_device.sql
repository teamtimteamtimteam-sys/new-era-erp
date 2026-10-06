-- db/functions/save_device.sql
-- MES-1(2026-10-06,MES-0 §3.2 · §5.2;MES-1 Step 0 Q6 · Q28,Tim):登记或修改一台设备 —— 设备登记唯一的写入口。
--   持 action.manage_devices。p_id 不给(为空)= 新登记(编号 DEV-YYYY-NNNN 由触发器生成,Q28);否则改那一台。
--   p_fields 只认下面这些键,别的键按名拒(DEVICE_FIELD_UNKNOWN|<键>)—— 一个打错的键不许安静地什么都没改:
--     name · kind(只在新登记时)· gateway_id · data_class · equipment_id · station · capacity · resolution · unit ·
--     protection_rating · interface_status · term_protocol · term_point_list · term_timestamp_precision · term_no_charge ·
--     term_retention_export · term_documentation · heartbeat_interval_s · notes
--   修改时只改给了的键;给一个键而值是 null = 清空它。
--   判据(各自按名拒):带它的网关必须是一台没停用的网关(DEVICE_GATEWAY_INVALID);资产卡要存在(DEVICE_EQUIPMENT_UNKNOWN);
--   数据类要在字典里(DEVICE_CLASS_UNKNOWN);种类定下不改、停用的冻住(守卫)。表上的 CHECK 管其余的形状。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.save_device(p_fields jsonb, p_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    c_keys constant text[] := ARRAY['name', 'kind', 'gateway_id', 'data_class', 'equipment_id', 'station', 'capacity',
        'resolution', 'unit', 'protection_rating', 'interface_status', 'term_protocol', 'term_point_list',
        'term_timestamp_precision', 'term_no_charge', 'term_retention_export', 'term_documentation',
        'heartbeat_interval_s', 'notes'];
    v_key  text;
    v_row  devices%ROWTYPE;
    v_id   uuid;
    f      jsonb := COALESCE(p_fields, '{}'::jsonb);
BEGIN
    PERFORM require_permission('action.manage_devices');
    IF jsonb_typeof(f) <> 'object' THEN
        RAISE EXCEPTION 'DEVICE_FIELD_UNKNOWN|?';
    END IF;
    FOR v_key IN SELECT jsonb_object_keys(f) LOOP
        IF NOT v_key = ANY (c_keys) THEN
            RAISE EXCEPTION 'DEVICE_FIELD_UNKNOWN|%', v_key;
        END IF;
    END LOOP;

    IF p_id IS NULL THEN
        v_row.name := f ->> 'name';
        v_row.kind := f ->> 'kind';
        v_row.interface_status := COALESCE(f ->> 'interface_status', 'reserved');
        v_row.term_protocol := COALESCE(f ->> 'term_protocol', 'not_confirmed');
        v_row.term_point_list := COALESCE(f ->> 'term_point_list', 'not_confirmed');
        v_row.term_timestamp_precision := COALESCE(f ->> 'term_timestamp_precision', 'not_confirmed');
        v_row.term_no_charge := COALESCE(f ->> 'term_no_charge', 'not_confirmed');
        v_row.term_retention_export := COALESCE(f ->> 'term_retention_export', 'not_confirmed');
        v_row.term_documentation := COALESCE(f ->> 'term_documentation', 'not_confirmed');
    ELSE
        SELECT * INTO v_row FROM devices WHERE id = p_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'DEVICE_NOT_FOUND';
        END IF;
        IF f ? 'kind' AND (f ->> 'kind') IS DISTINCT FROM v_row.kind THEN
            RAISE EXCEPTION 'DEVICE_KIND_FIXED|%', v_row.code;
        END IF;
        IF f ? 'name' THEN v_row.name := f ->> 'name'; END IF;
        IF f ? 'interface_status' THEN v_row.interface_status := f ->> 'interface_status'; END IF;
        IF f ? 'term_protocol' THEN v_row.term_protocol := f ->> 'term_protocol'; END IF;
        IF f ? 'term_point_list' THEN v_row.term_point_list := f ->> 'term_point_list'; END IF;
        IF f ? 'term_timestamp_precision' THEN v_row.term_timestamp_precision := f ->> 'term_timestamp_precision'; END IF;
        IF f ? 'term_no_charge' THEN v_row.term_no_charge := f ->> 'term_no_charge'; END IF;
        IF f ? 'term_retention_export' THEN v_row.term_retention_export := f ->> 'term_retention_export'; END IF;
        IF f ? 'term_documentation' THEN v_row.term_documentation := f ->> 'term_documentation'; END IF;
    END IF;
    IF p_id IS NULL OR f ? 'gateway_id' THEN v_row.gateway_id := NULLIF(f ->> 'gateway_id', '')::uuid; END IF;
    IF p_id IS NULL OR f ? 'data_class' THEN v_row.data_class := NULLIF(f ->> 'data_class', ''); END IF;
    IF p_id IS NULL OR f ? 'equipment_id' THEN v_row.equipment_id := NULLIF(f ->> 'equipment_id', '')::uuid; END IF;
    IF p_id IS NULL OR f ? 'station' THEN v_row.station := NULLIF(btrim(f ->> 'station'), ''); END IF;
    IF p_id IS NULL OR f ? 'capacity' THEN v_row.capacity := NULLIF(f ->> 'capacity', '')::numeric; END IF;
    IF p_id IS NULL OR f ? 'resolution' THEN v_row.resolution := NULLIF(f ->> 'resolution', '')::numeric; END IF;
    IF p_id IS NULL OR f ? 'unit' THEN v_row.unit := NULLIF(btrim(f ->> 'unit'), ''); END IF;
    IF p_id IS NULL OR f ? 'protection_rating' THEN v_row.protection_rating := NULLIF(btrim(f ->> 'protection_rating'), ''); END IF;
    IF p_id IS NULL OR f ? 'heartbeat_interval_s' THEN v_row.heartbeat_interval_s := NULLIF(f ->> 'heartbeat_interval_s', '')::integer; END IF;
    IF p_id IS NULL OR f ? 'notes' THEN v_row.notes := NULLIF(btrim(f ->> 'notes'), ''); END IF;
    v_row.name := btrim(COALESCE(v_row.name, ''));

    IF v_row.gateway_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM devices g WHERE g.id = v_row.gateway_id AND g.kind = 'gateway' AND g.retired_at IS NULL) THEN
        RAISE EXCEPTION 'DEVICE_GATEWAY_INVALID';
    END IF;
    IF v_row.equipment_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fixed_assets a WHERE a.id = v_row.equipment_id) THEN
        RAISE EXCEPTION 'DEVICE_EQUIPMENT_UNKNOWN';
    END IF;
    IF v_row.data_class IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ingest_data_classes c WHERE c.code = v_row.data_class) THEN
        RAISE EXCEPTION 'DEVICE_CLASS_UNKNOWN|%', v_row.data_class;
    END IF;

    IF p_id IS NULL THEN
        INSERT INTO devices (name, kind, gateway_id, data_class, equipment_id, station, capacity, resolution, unit,
                             protection_rating, interface_status, term_protocol, term_point_list, term_timestamp_precision,
                             term_no_charge, term_retention_export, term_documentation, heartbeat_interval_s, notes,
                             created_by, updated_by)
        VALUES (v_row.name, v_row.kind, v_row.gateway_id, v_row.data_class, v_row.equipment_id, v_row.station, v_row.capacity,
                v_row.resolution, v_row.unit, v_row.protection_rating, v_row.interface_status, v_row.term_protocol,
                v_row.term_point_list, v_row.term_timestamp_precision, v_row.term_no_charge, v_row.term_retention_export,
                v_row.term_documentation, v_row.heartbeat_interval_s, v_row.notes, auth.uid(), auth.uid())
        RETURNING id INTO v_id;
        RETURN v_id;
    END IF;
    UPDATE devices
       SET name = v_row.name, gateway_id = v_row.gateway_id, data_class = v_row.data_class, equipment_id = v_row.equipment_id,
           station = v_row.station, capacity = v_row.capacity, resolution = v_row.resolution, unit = v_row.unit,
           protection_rating = v_row.protection_rating, interface_status = v_row.interface_status,
           term_protocol = v_row.term_protocol, term_point_list = v_row.term_point_list,
           term_timestamp_precision = v_row.term_timestamp_precision, term_no_charge = v_row.term_no_charge,
           term_retention_export = v_row.term_retention_export, term_documentation = v_row.term_documentation,
           heartbeat_interval_s = v_row.heartbeat_interval_s, notes = v_row.notes, updated_by = auth.uid()
     WHERE id = p_id;
    RETURN p_id;
END;
$function$;
