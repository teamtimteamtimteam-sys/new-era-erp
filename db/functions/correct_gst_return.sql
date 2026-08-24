-- db/functions/correct_gst_return.sql
-- GST-1:更正是【一个新事件】,不是一次编辑 —— 与已签发单据同一条规矩。
-- 它建一份新的期间行(F7),corrects_period_id 指着被更正的那一份,
-- 而原来那一份原样保留、状态仍是 filed。理由必填:一次没有理由的更正日后无从交代。

CREATE OR REPLACE FUNCTION public.correct_gst_return(p_original_period_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_o gst_periods%ROWTYPE; v_id uuid; v_code text; v_n int;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'GST_CORRECTION_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_o FROM gst_periods WHERE id = p_original_period_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GST_PERIOD_NOT_FOUND|%', p_original_period_id; END IF;
    IF v_o.status <> 'filed' THEN
        RAISE EXCEPTION 'GST_CANNOT_CORRECT_UNFILED|%', v_o.code;
    END IF;
    SELECT count(*) INTO v_n FROM gst_periods WHERE corrects_period_id = p_original_period_id;
    v_code := v_o.code || '-F7-' || (v_n + 1)::text;
    INSERT INTO gst_periods (code, period_start, period_end, status, notes, corrects_period_id)
    VALUES (v_code, v_o.period_start, v_o.period_end, 'open', p_reason, p_original_period_id)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('gst_period_id', v_id, 'code', v_code,
                              'corrects', v_o.code, 'reason', p_reason);
END;
$function$;