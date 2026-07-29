CREATE OR REPLACE FUNCTION public.reopen_period(p_period_end date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_close_id uuid;
    v_new_lock date;
BEGIN
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 与 close_period 同一把锁,串行化
    PERFORM 1 FROM finance_settings WHERE id FOR UPDATE;

    SELECT id INTO v_close_id
    FROM period_closes
    WHERE period_end = p_period_end AND reopened_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM period_closes WHERE period_end = p_period_end) THEN
            RAISE EXCEPTION 'ALREADY_REOPENED';
        END IF;
        RAISE EXCEPTION 'CLOSE_NOT_FOUND';
    END IF;

    UPDATE period_closes
    SET reopened_at = now(), reopened_by = auth.uid(), reopen_reason = btrim(p_reason)
    WHERE id = v_close_id;

    -- 更早的仍有效关账 → 其 period_end + 1;没有 → 解除锁定
    SELECT MAX(period_end) + 1 INTO v_new_lock
    FROM period_closes
    WHERE reopened_at IS NULL AND period_end < p_period_end;

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock
    );
END;
$function$

