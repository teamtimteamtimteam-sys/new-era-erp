CREATE OR REPLACE FUNCTION public.record_fx_rates_bulk(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row   jsonb;
    v_idx   integer := 0;
    v_done  integer := 0;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
        RAISE EXCEPTION 'FX_BULK_INVALID';
    END IF;
    IF jsonb_array_length(p_rows) = 0 THEN
        RAISE EXCEPTION 'FX_BULK_EMPTY';
    END IF;

    FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
        v_idx := v_idx + 1;
        BEGIN
            -- 【就是那一个函数】校验、留痕、未来日期的拒绝,全在它里面。
            -- p_reason 恒为 NULL:批量只【填空】,不覆盖 —— 已在册的那一格
            -- 会被 record_fx_rate 自己按 FX_RATE_EXISTS 挡回来。
            PERFORM record_fx_rate(
                v_row->>'currency',
                (v_row->>'rate_date')::date,
                v_row->>'rate_type',
                (v_row->>'rate')::numeric,
                COALESCE(v_row->>'source', 'DBS'),
                NULLIF(btrim(COALESCE(v_row->>'notes', '')), ''),
                NULL);
            v_done := v_done + 1;
        EXCEPTION WHEN OTHERS THEN
            -- 【带上第几行再抛】整笔事务照样回滚(全有或全无),
            -- 但人得知道是哪一格。
            RAISE EXCEPTION 'FX_BULK_ROW|%|%', v_idx, SQLERRM;
        END;
    END LOOP;

    RETURN jsonb_build_object('recorded', v_done);
END;
$function$;