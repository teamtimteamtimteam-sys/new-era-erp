CREATE OR REPLACE FUNCTION public.withdraw_fx_rate(p_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_r record;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF btrim(COALESCE(p_reason, '')) = '' THEN
        RAISE EXCEPTION 'FX_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_r FROM fx_rates WHERE id = p_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FX_RATE_NOT_FOUND|%', p_id;
    END IF;

    PERFORM set_config('evoltrya.fx_ctx', 'withdraw_fx_rate', true);
    UPDATE fx_rates SET deleted_at = now(), updated_by = auth.uid() WHERE id = p_id;
    INSERT INTO fx_rate_history (fx_rate_id, action, currency, rate_date, rate_type,
                                 rate_sgd_per_unit, prev_rate, source, notes, reason)
    VALUES (p_id, 'withdrawn', v_r.currency, v_r.rate_date, v_r.rate_type,
            v_r.rate_sgd_per_unit, v_r.rate_sgd_per_unit, v_r.source, v_r.notes, btrim(p_reason));
    PERFORM set_config('evoltrya.fx_ctx', '', true);
END;
$function$;