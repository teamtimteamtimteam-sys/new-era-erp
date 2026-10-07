-- db/functions/assert_quarantine_landing.sql
-- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q19,Tim):【带着要隔离的状态,就只能落进隔离库位】。
--   p_states:这一批身上的状态(收货:请求里的 p_safety_states;转移:这一批【开着的】状态)。其中任何一个
--   requires_quarantine = true(引导:swollen_leaking),而落点不是一个【在用的】隔离库位 →
--   QUARANTINE_LOCATION_REQUIRED|<状态>|<库位编号,或 unspecified>。【未指定库位不是隔离】。
--   requires_quarantine 为 NULL(没定,V4)当作不要 —— 一个没人给过的规矩不拦人。
--   调用方:create_inbound_batch · receive_inbound_batch_against_po(写入之前)· create_stock_transfer(入腿)。
--   【记下一个状态永远不经过这里】—— 一个危险必须永远记得下来;已经放在别处的,由提醒臂 quarantine_required 标出来(Q20)。
--   内层:不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.assert_quarantine_landing(p_states text[], p_location_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_state text;
BEGIN
    SELECT s.code INTO v_state
      FROM inbound_safety_states s
     WHERE s.code = ANY (COALESCE(p_states, ARRAY[]::text[])) AND s.requires_quarantine IS TRUE
     ORDER BY s.sort_order, s.code
     LIMIT 1;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    IF p_location_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM storage_locations l WHERE l.id = p_location_id AND l.is_active AND l.is_quarantine) THEN
        RETURN;
    END IF;
    RAISE EXCEPTION 'QUARANTINE_LOCATION_REQUIRED|%|%', v_state,
        COALESCE((SELECT l.code FROM storage_locations l WHERE l.id = p_location_id), 'unspecified');
END;
$function$;
