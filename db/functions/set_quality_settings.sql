-- db/functions/set_quality_settings.sql
-- MES-6a-1(2026-10-09,MES-0 §5.1 V16;MES-6a Step 0 Q14,Tim):【写下(或清空)V16 —— 没有合同天数的样品留多少天】。
--   module.quality.edit。NULL = 清空(回到 Not yet set);给了就必须 > 0(QUALITY_RETENTION_DAYS_INVALID)。
--   ★ 不回头改已有的样品(retain_until 在建的那一刻抄下,Q8)。改动进变更记录(主语 quality_settings,画在 /quality/samples)。
--   返回 {internal_retention_days}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.set_quality_settings(p_internal_retention_days integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.quality.edit');
    IF p_internal_retention_days IS NOT NULL AND p_internal_retention_days <= 0 THEN
        RAISE EXCEPTION 'QUALITY_RETENTION_DAYS_INVALID|%', p_internal_retention_days;
    END IF;
    UPDATE quality_settings SET internal_retention_days = p_internal_retention_days, updated_by = auth.uid() WHERE id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QUALITY_SETTINGS_MISSING';
    END IF;
    RETURN jsonb_build_object('internal_retention_days', p_internal_retention_days);
END;
$function$
