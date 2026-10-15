-- db/functions/downtime_cause_check.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3):【这个原因代号能不能用】—— 开一段停机与更正一段停机共用的一句判据。
--   空 → DOWNTIME_CAUSE_REQUIRED;不在清单里 → DOWNTIME_CAUSE_UNKNOWN|<代号>;停用 → DOWNTIME_CAUSE_INACTIVE|<代号>。
--   返回它的类别(failure · planned · external)。表上的 guard_downtime_cause 是同一条规矩的第二道(属主路径也过它)。
--   【内层】EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.downtime_cause_check(p_cause_code text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c record;
BEGIN
    IF p_cause_code IS NULL OR btrim(p_cause_code) = '' THEN
        RAISE EXCEPTION 'DOWNTIME_CAUSE_REQUIRED';
    END IF;
    SELECT c.class, c.is_active INTO v_c FROM downtime_causes c WHERE c.code = p_cause_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOWNTIME_CAUSE_UNKNOWN|%', p_cause_code;
    END IF;
    IF NOT v_c.is_active THEN
        RAISE EXCEPTION 'DOWNTIME_CAUSE_INACTIVE|%', p_cause_code;
    END IF;
    RETURN v_c.class;
END;
$function$;
