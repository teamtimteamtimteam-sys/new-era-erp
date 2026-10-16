-- db/functions/set_compliance_settings.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q18 · Q28,Tim):【给 V26 与 V27】—— NEA 申报的格式与频率、欧盟回收效率的方法与目标(compliance_settings 那一行)。
--   门 action.compliance_pack(冻包的人;cto · admin)。每一格:空串读作"还没给"(NULL),不是一句空话;两两成对 —— 只给格式不给频率、
--   只给方法不给目标都按名拒(COMPLIANCE_SETTINGS_PAIR_INCOMPLETE|V26 / |V27):半句标准在包上会读成一句完整的。
--   给了也不算任何东西(Q28)。修改史在变更记录里。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.set_compliance_settings(p_nea_return_format text, p_nea_return_frequency text, p_eu_efficiency_method text, p_eu_efficiency_targets text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f  text := NULLIF(btrim(COALESCE(p_nea_return_format, '')), '');
    v_q  text := NULLIF(btrim(COALESCE(p_nea_return_frequency, '')), '');
    v_m  text := NULLIF(btrim(COALESCE(p_eu_efficiency_method, '')), '');
    v_t  text := NULLIF(btrim(COALESCE(p_eu_efficiency_targets, '')), '');
BEGIN
    PERFORM require_permission('action.compliance_pack');
    IF (v_f IS NULL) <> (v_q IS NULL) THEN
        RAISE EXCEPTION 'COMPLIANCE_SETTINGS_PAIR_INCOMPLETE|V26';
    END IF;
    IF (v_m IS NULL) <> (v_t IS NULL) THEN
        RAISE EXCEPTION 'COMPLIANCE_SETTINGS_PAIR_INCOMPLETE|V27';
    END IF;
    UPDATE compliance_settings
       SET nea_return_format = v_f, nea_return_frequency = v_q, eu_efficiency_method = v_m, eu_efficiency_targets = v_t,
           updated_by = auth.uid()
     WHERE id;
    RETURN (SELECT to_jsonb(s) - 'id' FROM compliance_settings s WHERE s.id);
END;
$function$
