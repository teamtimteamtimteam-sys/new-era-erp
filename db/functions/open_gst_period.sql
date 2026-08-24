-- db/functions/open_gst_period.sql
-- GST-1:开一个季度。新加坡的标准申报周期是一个季;要按月或按半年是 IRAS 批准的事,
-- 不由这里猜,所以不是整季就按名拒。

CREATE OR REPLACE FUNCTION public.open_gst_period(p_period_start date, p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_code text; v_id uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'GST_PERIOD_DATES_REQUIRED';
    END IF;
    -- 【季度的形状】新加坡的标准申报周期是一个季;要按月/按半年是另一回事,
    -- 到时候由 IRAS 的批准决定,不由这里猜。
    IF p_period_start <> date_trunc('quarter', p_period_start)::date
       OR p_period_end <> (date_trunc('quarter', p_period_start) + interval '3 months - 1 day')::date THEN
        RAISE EXCEPTION 'GST_PERIOD_NOT_A_QUARTER|%|%', p_period_start, p_period_end;
    END IF;
    IF EXISTS (SELECT 1 FROM gst_periods WHERE period_start = p_period_start AND corrects_period_id IS NULL) THEN
        RAISE EXCEPTION 'GST_PERIOD_EXISTS|%', p_period_start;
    END IF;
    v_code := 'GST-' || to_char(p_period_start,'YYYY') || '-Q'
              || EXTRACT(quarter FROM p_period_start)::text;
    INSERT INTO gst_periods (code, period_start, period_end, status)
    VALUES (v_code, p_period_start, p_period_end, 'open') RETURNING id INTO v_id;
    RETURN jsonb_build_object('gst_period_id', v_id, 'code', v_code,
                              'period_start', p_period_start, 'period_end', p_period_end);
END;
$function$;