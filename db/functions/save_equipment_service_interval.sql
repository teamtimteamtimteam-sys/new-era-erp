-- db/functions/save_equipment_service_interval.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q6,Tim):【存一条保养间隔】(新的,或改一条已有的)—— 取代 EQP-2d 的直连 INSERT / UPDATE。
--   门 module.processing.edit。p_interval_id 为空 = 新加一条;否则改那一条(它必须属于这台机器:INTERVAL_OTHER_MACHINE)。
--   删一条间隔(= 回到「未监控」)仍走表上的 DELETE 策略,不在这里 —— 那张表的注释说明了删行与 ignore 是两件事。
--   按名拒(此前是约束名):不是一台在册的机器 · INTERVAL_NOT_FOUND|<id> · INTERVAL_KIND_INVALID|<种类> · INTERVAL_NOTHING_STATED
--   (公斤与天数至少说出一个)· INTERVAL_VALUE_INVALID|kg 或 days(间隔必须 > 0)· INTERVAL_LEAD_REQUIRED|kg 或 days
--   (给了间隔就要给提前量;0 是一个决定 = 不提前警告)· INTERVAL_LEAD_NOT_BELOW|kg 或 days(提前量在 0 与间隔之间,不含间隔 ——
--   等于间隔是一盏从第一天就亮着的灯)· INTERVAL_DISPOSITION_INVALID|<值> · INTERVAL_ALREADY_SET|<种类>(一台机器一种活一条)。
--   量度为空时它的提前量一并清空(表单上看不见的旧值不许跟着提交)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.save_equipment_service_interval(p_equipment_id uuid, p_interval_id uuid, p_kind text, p_interval_kg numeric, p_lead_kg numeric, p_interval_days integer, p_lead_days integer, p_disposition text DEFAULT 'warn'::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_cur  equipment_service_intervals%ROWTYPE;
    v_lkg  numeric := CASE WHEN p_interval_kg IS NULL THEN NULL ELSE p_lead_kg END;
    v_ldy  integer := CASE WHEN p_interval_days IS NULL THEN NULL ELSE p_lead_days END;
    v_id   uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    v_code := equipment_record_target(p_equipment_id);
    IF p_interval_id IS NOT NULL THEN
        SELECT * INTO v_cur FROM equipment_service_intervals WHERE id = p_interval_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INTERVAL_NOT_FOUND|%', p_interval_id;
        END IF;
        IF v_cur.equipment_id <> p_equipment_id THEN
            RAISE EXCEPTION 'INTERVAL_OTHER_MACHINE|%', v_code;
        END IF;
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('service', 'repair') THEN
        RAISE EXCEPTION 'INTERVAL_KIND_INVALID|%', COALESCE(p_kind, '?');
    END IF;
    IF p_interval_kg IS NULL AND p_interval_days IS NULL THEN
        RAISE EXCEPTION 'INTERVAL_NOTHING_STATED';
    END IF;
    IF p_interval_kg IS NOT NULL AND p_interval_kg <= 0 THEN
        RAISE EXCEPTION 'INTERVAL_VALUE_INVALID|kg';
    END IF;
    IF p_interval_days IS NOT NULL AND p_interval_days <= 0 THEN
        RAISE EXCEPTION 'INTERVAL_VALUE_INVALID|days';
    END IF;
    IF p_interval_kg IS NOT NULL AND v_lkg IS NULL THEN
        RAISE EXCEPTION 'INTERVAL_LEAD_REQUIRED|kg';
    END IF;
    IF p_interval_days IS NOT NULL AND v_ldy IS NULL THEN
        RAISE EXCEPTION 'INTERVAL_LEAD_REQUIRED|days';
    END IF;
    IF v_lkg IS NOT NULL AND (v_lkg < 0 OR v_lkg >= p_interval_kg) THEN
        RAISE EXCEPTION 'INTERVAL_LEAD_NOT_BELOW|kg';
    END IF;
    IF v_ldy IS NOT NULL AND (v_ldy < 0 OR v_ldy >= p_interval_days) THEN
        RAISE EXCEPTION 'INTERVAL_LEAD_NOT_BELOW|days';
    END IF;
    IF p_disposition IS NULL OR p_disposition NOT IN ('warn', 'ignore') THEN
        RAISE EXCEPTION 'INTERVAL_DISPOSITION_INVALID|%', COALESCE(p_disposition, '?');
    END IF;
    IF EXISTS (SELECT 1 FROM equipment_service_intervals i
                WHERE i.equipment_id = p_equipment_id AND i.kind = p_kind AND i.id IS DISTINCT FROM p_interval_id) THEN
        RAISE EXCEPTION 'INTERVAL_ALREADY_SET|%', p_kind;
    END IF;
    BEGIN
    IF p_interval_id IS NULL THEN
        INSERT INTO equipment_service_intervals (equipment_id, kind, interval_kg, lead_kg, interval_days, lead_days, disposition, notes,
                                                 created_by, updated_by)
        VALUES (p_equipment_id, p_kind, p_interval_kg, v_lkg, p_interval_days, v_ldy, p_disposition,
                NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid(), auth.uid())
        RETURNING id INTO v_id;
    ELSE
        UPDATE equipment_service_intervals
           SET kind = p_kind, interval_kg = p_interval_kg, lead_kg = v_lkg, interval_days = p_interval_days, lead_days = v_ldy,
               disposition = p_disposition, notes = NULLIF(btrim(COALESCE(p_notes, '')), ''), updated_at = now(), updated_by = auth.uid()
         WHERE id = p_interval_id;
        v_id := p_interval_id;
    END IF;
    EXCEPTION WHEN unique_violation THEN
        -- 同一刻两个人给同一种活各加一条(唯一键 one_per_kind 是并发兜底):说成同一句
        RAISE EXCEPTION 'INTERVAL_ALREADY_SET|%', p_kind;
    END;
    RETURN jsonb_build_object('interval_id', v_id, 'equipment_id', p_equipment_id, 'equipment_code', v_code);
END;
$function$;
