-- db/functions/guard_safety_state_rows.sql
-- MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q22 · Q23,Tim):两张安全状态表(进料批 · 产出批)共用的守卫。
--   ① 删除 / 清空一律拒,属主路径也拒:SAFETY_STATE_NEVER_DELETED|<表>。状态被【结束】,不被删(批次本身不能硬删,
--      所以 ON DELETE CASCADE 走不到这里)。
--   ② 直连写(row_security_active = 真:从一个会话直接 INSERT / UPDATE)按名拒:SAFETY_STATES_THROUGH_FUNCTION_ONLY|<表>|<操作>。
--      写只经 set_inbound_safety_states · set_output_safety_states · 两支收货函数 · 加工的提交与回滚(都是 SECURITY DEFINER)。
--      语句级那一支管"零行的 UPDATE"(没有 UPDATE 策略时它在 RLS 那里是零行,行级触发器不醒 —— SILENT-1 那一族)。
--   ③ 属主路径上的 UPDATE 只许做一件事:把一条【开着的】行结束一次 —— ended_at 填上、理由不空,别的列一格都不动。
--      已经结束的 → SAFETY_STATE_ALREADY_ENDED|<状态>;改了别的列或把 ended_at 改回空 → SAFETY_STATE_ROW_FIXED|<表>;
--      结束没理由 → SAFETY_STATE_END_REASON_REQUIRED|<状态>(表上的 CHECK 是第二道)。
--   【为什么是 INVOKER】row_security_active 必须反映【调用者】的视角(guard_processing_direct_write 同一个理由)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.guard_safety_state_rows()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP IN ('DELETE', 'TRUNCATE') THEN
        RAISE EXCEPTION 'SAFETY_STATE_NEVER_DELETED|%', TG_TABLE_NAME;
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'SAFETY_STATES_THROUGH_FUNCTION_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
    END IF;
    IF TG_LEVEL = 'STATEMENT' THEN
        RETURN NULL;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.ended_at IS NOT NULL THEN
            RAISE EXCEPTION 'SAFETY_STATE_ALREADY_ENDED|%', OLD.safety_state_code;
        END IF;
        IF NEW.ended_at IS NULL
           OR (to_jsonb(NEW) - ARRAY['ended_at', 'ended_by', 'end_reason', 'ended_by_run_id'])
              IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['ended_at', 'ended_by', 'end_reason', 'ended_by_run_id']) THEN
            RAISE EXCEPTION 'SAFETY_STATE_ROW_FIXED|%', TG_TABLE_NAME;
        END IF;
        IF btrim(COALESCE(NEW.end_reason, '')) = '' THEN
            RAISE EXCEPTION 'SAFETY_STATE_END_REASON_REQUIRED|%', OLD.safety_state_code;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;
