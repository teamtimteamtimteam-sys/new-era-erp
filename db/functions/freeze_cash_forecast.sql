CREATE OR REPLACE FUNCTION public.freeze_cash_forecast(p_week_start date DEFAULT NULL::date, p_supersede_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ws   date;
    v_d    jsonb;
    v_prev cash_forecasts%ROWTYPE;
    v_code text;
    v_id   uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');

    v_ws := COALESCE(p_week_start, date_trunc('week', CURRENT_DATE)::date);
    IF v_ws <> date_trunc('week', v_ws)::date THEN
        RAISE EXCEPTION 'FORECAST_WEEK_START_NOT_MONDAY|%', v_ws::text;
    END IF;

    -- 同一周已经冻过 → 这是【重出】,要理由;旧的那一份【不删】,
    -- 因为 T1 的偏差正是拿它去比的,覆盖掉就把那个度量本身毁了。
    SELECT * INTO v_prev FROM cash_forecasts
     WHERE week_start = v_ws AND superseded_at IS NULL LIMIT 1;
    IF FOUND AND (p_supersede_reason IS NULL OR btrim(p_supersede_reason) = '') THEN
        RAISE EXCEPTION 'FORECAST_SUPERSEDE_REASON_REQUIRED|%|%', v_prev.code, v_ws::text;
    END IF;

    v_d := cash_forecast_data(v_ws);
    v_code := next_forecast_code(v_ws);

    INSERT INTO cash_forecasts (code, week_start, horizon_weeks, opening, buckets, lines,
                                undated, promises_memo, buffer, base_currency, frozen_by)
    VALUES (v_code, v_ws, 13, v_d->'opening', v_d->'buckets', v_d->'lines',
            v_d->'undated', v_d->'promises_memo', v_d->'buffer', v_d->>'base_currency', auth.uid())
    RETURNING id INTO v_id;

    IF v_prev.id IS NOT NULL THEN
        UPDATE cash_forecasts
           SET superseded_at = now(), superseded_by = v_id,
               superseded_reason = btrim(p_supersede_reason)
         WHERE id = v_prev.id;
    END IF;

    RETURN jsonb_build_object('forecast_id', v_id, 'code', v_code, 'week_start', v_ws,
                              'superseded', v_prev.code);
END;
$function$

;
