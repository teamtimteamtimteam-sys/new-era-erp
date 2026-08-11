CREATE OR REPLACE FUNCTION public.preview_metal_price_anomalies(p_price_date date, p_prices jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_el     jsonb;
    v_metal  text;
    v_raw    text;
    v_price  numeric;
    v_out    jsonb := '[]'::jsonb;
    v_exists uuid;
BEGIN
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;
    IF p_prices IS NULL OR jsonb_typeof(p_prices) <> 'array' THEN
        RAISE EXCEPTION 'NO_PRICES';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_prices)
    LOOP
        v_metal := v_el->>'metal';
        v_raw   := v_el->>'price_usd_per_tonne';
        -- 空格子跳过 —— 与 upsert_metal_prices 同一条:每日表单常常只填几个金属
        CONTINUE WHEN v_raw IS NULL OR btrim(v_raw) = '';
        v_price := v_raw::numeric;
        CONTINUE WHEN v_price IS NULL OR v_price <= 0;

        -- 覆盖已有的同日行时,那一行自己不能当参照
        SELECT id INTO v_exists FROM metal_prices
         WHERE metal = v_metal AND price_date = p_price_date AND deleted_at IS NULL;

        v_out := v_out || jsonb_build_array(
            metal_price_anomaly(v_metal, v_price, p_price_date, v_exists));
    END LOOP;

    RETURN v_out;
END;
$function$;