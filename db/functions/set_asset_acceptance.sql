CREATE OR REPLACE FUNCTION public.set_asset_acceptance(p_asset_id uuid, p_acceptance_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_acq  date;
BEGIN
    PERFORM require_permission('module.finance.edit');

    IF p_acceptance_date IS NULL THEN
        RAISE EXCEPTION 'ACCEPTANCE_DATE_REQUIRED'
          USING HINT = '验收日期不给默认值 —— 一个默认出来的验收日是在替一次没发生过的验收签字';
    END IF;

    SELECT code, acquisition_date INTO v_code, v_acq
    FROM fixed_assets WHERE id = p_asset_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(p_asset_id::text, '?');
    END IF;
    IF p_acceptance_date < v_acq THEN
        RAISE EXCEPTION 'ASSET_ACCEPTANCE_BEFORE_ACQUISITION|%|%|%', v_code, p_acceptance_date, v_acq;
    END IF;

    UPDATE fixed_assets SET acceptance_date = p_acceptance_date WHERE id = p_asset_id;

    RETURN jsonb_build_object('asset_id', p_asset_id, 'code', v_code,
                              'acceptance_date', p_acceptance_date);
END;
$function$