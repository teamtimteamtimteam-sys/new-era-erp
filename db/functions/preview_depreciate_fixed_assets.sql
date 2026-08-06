-- db/functions/preview_depreciate_fixed_assets.sql
-- 折旧算术的【唯一来源】(FIN-22)。writer(depreciate_fixed_assets)问它,界面也问它 ——
-- 屏幕预览和真正过账共用同一份算术(ask-the-database 规矩,重估的同款结构)。
-- 目标累计 = LEAST(成本−残值, (成本−残值)/年限月数 × 在役月数);在役月数含首月/末月
-- 按天折算,从【在役日】起算,不从购置日。应提 = 目标 − Σ 已提(recorded)。
-- 负差额报 0:残值/年限被改动导致的下修是【更正】,走人工分录,不由月度例程悄悄回冲。

CREATE OR REPLACE FUNCTION public.preview_depreciate_fixed_assets(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rows   jsonb := '[]'::jsonb;
    v_total  numeric := 0;
    v_a      record;
    v_months numeric;
    v_m0     date;
    v_mn     date;
    v_target numeric;
    v_posted numeric;
    v_delta  numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    FOR v_a IN
        SELECT fa.id, fa.code, fa.description, fa.in_service_date, fa.cost_base,
               fa.residual_base, fa.useful_life_months, fa.depreciation_account_code
        FROM fixed_assets fa
        WHERE fa.status = 'active'
        ORDER BY fa.code
    LOOP
        -- 在役月数(含首月/末月按天折算)。未投用或期末早于在役日 → 0。
        IF v_a.in_service_date IS NULL OR p_period_end < v_a.in_service_date THEN
            v_months := 0;
        ELSE
            v_m0 := date_trunc('month', v_a.in_service_date)::date;
            v_mn := date_trunc('month', p_period_end)::date;
            IF v_m0 = v_mn THEN
                v_months := (p_period_end - v_a.in_service_date + 1)::numeric
                            / EXTRACT(day FROM (v_m0 + interval '1 month - 1 day'))::numeric;
            ELSE
                v_months :=
                    ((v_m0 + interval '1 month - 1 day')::date - v_a.in_service_date + 1)::numeric
                        / EXTRACT(day FROM (v_m0 + interval '1 month - 1 day'))::numeric
                    + (EXTRACT(year FROM age(v_mn, v_m0 + interval '1 month'))::numeric * 12
                       + EXTRACT(month FROM age(v_mn, v_m0 + interval '1 month'))::numeric)
                    + EXTRACT(day FROM p_period_end)::numeric
                        / EXTRACT(day FROM (v_mn + interval '1 month - 1 day'))::numeric;
            END IF;
        END IF;

        v_target := LEAST(round(v_a.cost_base - v_a.residual_base, 2),
                          round((v_a.cost_base - v_a.residual_base)
                                / v_a.useful_life_months * v_months, 2));
        SELECT COALESCE(SUM(d.amount_base), 0) INTO v_posted
        FROM fixed_asset_depreciation d WHERE d.asset_id = v_a.id;
        v_delta := round(v_target - v_posted, 2);
        -- 负差额不冲回:残值/年限被改动导致的目标下修是【更正】,走人工分录,
        -- 不由月度例程悄悄回冲。这里报 0。
        IF v_delta < 0 THEN v_delta := 0; END IF;
        v_total := v_total + v_delta;

        v_rows := v_rows || jsonb_build_object(
            'asset_id', v_a.id, 'code', v_a.code, 'description', v_a.description,
            'account', v_a.depreciation_account_code,
            'target_base', v_target, 'posted_base', v_posted, 'delta_base', v_delta);
    END LOOP;

    RETURN jsonb_build_object('period_end', p_period_end, 'rows', v_rows,
                              'total_delta', round(v_total, 2));
END;
$function$;
