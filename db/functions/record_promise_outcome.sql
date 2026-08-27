CREATE OR REPLACE FUNCTION public.record_promise_outcome(p_promise_id uuid, p_outcome text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p collection_promises%ROWTYPE;
    v_ch collection_chases%ROWTYPE;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_p FROM collection_promises WHERE id = p_promise_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PROMISE_NOT_FOUND|%', COALESCE(p_promise_id::text, '?');
    END IF;
    IF v_p.outcome IS NOT NULL THEN
        -- 结局记下之后不可改 —— 它与催收记录本身同一条:一件发生过的事。
        RAISE EXCEPTION 'PROMISE_OUTCOME_ALREADY_RECORDED|%|%',
            v_p.outcome, v_p.outcome_recorded_at::date::text;
    END IF;
    IF p_outcome IS NULL OR p_outcome NOT IN ('kept','broken','renegotiated','cancelled') THEN
        RAISE EXCEPTION 'PROMISE_OUTCOME_INVALID|%', COALESCE(p_outcome, '?');
    END IF;
    SELECT * INTO v_ch FROM collection_chases WHERE id = v_p.chase_id;
    IF v_ch.superseded_at IS NOT NULL THEN
        -- 一条被取代的催收上的承诺已经不成立了,给它记结局是在给一件
        -- 已经作废的东西下判断。
        RAISE EXCEPTION 'PROMISE_CHASE_SUPERSEDED|%', v_ch.code;
    END IF;

    UPDATE collection_promises
       SET outcome = p_outcome,
           outcome_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
           outcome_recorded_at = now(),
           outcome_recorded_by = auth.uid()
     WHERE id = p_promise_id;

    RETURN jsonb_build_object('promise_id', p_promise_id, 'outcome', p_outcome,
                              'chase_code', v_ch.code);
END;
$function$

;
