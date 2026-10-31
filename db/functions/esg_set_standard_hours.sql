-- db/functions/esg_set_standard_hours.sql
-- ESG-2(Tim 2026-10-31 Q4 · Q9):设定一个工作日算几个小时(安全率的工时分母)。要 action.manage_esg(admin · cco · cfo)。
--   按名拒:ESG_STANDARD_HOURS_INVALID(空、≤ 0 或 > 24)· ESG_STANDARD_HOURS_NO_CHANGE。修改史在变更记录里(esg_settings 绑着)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_set_standard_hours(p_hours numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old numeric;
BEGIN
    PERFORM require_permission('action.manage_esg');
    IF p_hours IS NULL OR p_hours <= 0 OR p_hours > 24 THEN
        RAISE EXCEPTION 'ESG_STANDARD_HOURS_INVALID';
    END IF;
    SELECT standard_hours_per_day INTO v_old FROM esg_settings WHERE id;
    IF v_old IS NOT DISTINCT FROM p_hours THEN
        RAISE EXCEPTION 'ESG_STANDARD_HOURS_NO_CHANGE';
    END IF;
    UPDATE esg_settings SET standard_hours_per_day = p_hours, updated_by = auth.uid() WHERE id;
    RETURN jsonb_build_object('standard_hours_per_day', p_hours, 'previous', v_old);
END;
$function$;
