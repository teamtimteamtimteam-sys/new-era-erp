-- db/functions/esg_set_grid_factor.sql
-- ESG-2(Tim 2026-10-31 Q1 · Q2 · Q9):设定某一年的电网排放因子(kg CO2/kWh)。要 action.manage_esg(admin · cco · cfo)。
--   同一年第一次 = 第一个版本(理由可空);那一年已经有了 = 更正,是一个【新版本】,理由必填(Q2);与那一年现在的值和出处都一样 → 按名拒。
--   按名拒:ESG_GRID_FACTOR_YEAR_INVALID(2000–2100 之外或空)· ESG_GRID_FACTOR_VALUE_INVALID(不是 0 < 值 < 5)·
--     ESG_GRID_FACTOR_SOURCE_REQUIRED · ESG_GRID_FACTOR_REASON_REQUIRED|<年>(更正没写理由)· ESG_GRID_FACTOR_NO_CHANGE|<年>。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_set_grid_factor(p_year integer, p_kg_co2_per_kwh numeric, p_source text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cur grid_emission_factors%ROWTYPE;
    v_id  bigint;
BEGIN
    PERFORM require_permission('action.manage_esg');
    IF p_year IS NULL OR p_year NOT BETWEEN 2000 AND 2100 THEN
        RAISE EXCEPTION 'ESG_GRID_FACTOR_YEAR_INVALID';
    END IF;
    IF p_kg_co2_per_kwh IS NULL OR p_kg_co2_per_kwh <= 0 OR p_kg_co2_per_kwh >= 5 THEN
        RAISE EXCEPTION 'ESG_GRID_FACTOR_VALUE_INVALID';
    END IF;
    IF p_source IS NULL OR btrim(p_source) = '' THEN
        RAISE EXCEPTION 'ESG_GRID_FACTOR_SOURCE_REQUIRED';
    END IF;
    SELECT * INTO v_cur FROM grid_emission_factors g WHERE g.factor_year = p_year ORDER BY g.id DESC LIMIT 1;
    IF FOUND THEN
        IF v_cur.kg_co2_per_kwh = p_kg_co2_per_kwh AND v_cur.source = btrim(p_source) THEN
            RAISE EXCEPTION 'ESG_GRID_FACTOR_NO_CHANGE|%', p_year;
        END IF;
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
            RAISE EXCEPTION 'ESG_GRID_FACTOR_REASON_REQUIRED|%', p_year;
        END IF;
    END IF;
    INSERT INTO grid_emission_factors (factor_year, kg_co2_per_kwh, source, reason, recorded_by)
    VALUES (p_year, p_kg_co2_per_kwh, btrim(p_source), NULLIF(btrim(COALESCE(p_reason, '')), ''), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id, 'factor_year', p_year, 'correction', v_cur.id IS NOT NULL);
END;
$function$;
