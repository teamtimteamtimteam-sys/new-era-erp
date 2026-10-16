-- db/functions/set_safety_settings.sql
-- MES-7b-1(2026-10-16,MES-0 §5.1 V19 · Q93;MES-7b Step 0 Q11,Tim):【改 V19 / 对着执照确认它】—— module.safety.edit。
--   p_nea_report_working_days:书面报告的工作日数(空 = Not yet set;> 0,否则 SAFETY_REPORT_DAYS_INVALID)。
--   p_confirmed:true = 这个数已经对着 NEA 执照核过(记下确认的时刻与人);false = 未确认(期限照算,标"未确认",V19 留在待补的值上)。
--     没有数不能确认(SAFETY_CONFIRM_NEEDS_VALUE)。【改了数而不确认,就回到未确认】—— 一个改过的数不继承上一个数的确认。
--   p_source:这个数从哪里来(可选,例如执照的条款号);空 = 清掉引导值那句出处(那句说的是引导值,不是新数)。
--   修改史在变更记录里(主语 safety_settings)。返回这一行。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.set_safety_settings(p_nea_report_working_days integer, p_confirmed boolean, p_source text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_row  safety_settings%ROWTYPE;
BEGIN
    PERFORM require_permission('module.safety.edit');
    IF p_nea_report_working_days IS NOT NULL AND p_nea_report_working_days < 1 THEN
        RAISE EXCEPTION 'SAFETY_REPORT_DAYS_INVALID';
    END IF;
    IF COALESCE(p_confirmed, false) AND p_nea_report_working_days IS NULL THEN
        RAISE EXCEPTION 'SAFETY_CONFIRM_NEEDS_VALUE';
    END IF;
    UPDATE safety_settings
       SET nea_report_working_days = p_nea_report_working_days,
           nea_report_days_source = NULLIF(btrim(COALESCE(p_source, '')), ''),
           nea_report_days_confirmed_at = CASE WHEN COALESCE(p_confirmed, false) THEN now() END,
           nea_report_days_confirmed_by = CASE WHEN COALESCE(p_confirmed, false) THEN v_user END,
           updated_by = v_user
     WHERE id
    RETURNING * INTO v_row;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SAFETY_SETTINGS_MISSING';
    END IF;
    RETURN to_jsonb(v_row);
END;
$function$;
