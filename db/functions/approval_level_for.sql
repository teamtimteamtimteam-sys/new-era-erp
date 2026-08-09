CREATE OR REPLACE FUNCTION public.approval_level_for(p_amount_base numeric)
 RETURNS smallint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_threshold numeric;
BEGIN
    SELECT approval_threshold_base INTO v_threshold FROM finance_settings LIMIT 1;
    IF v_threshold IS NULL THEN
        -- 【没设好的管控不等于可以跳过管控】—— 猜一个级别等于把审批变成装饰
        RAISE EXCEPTION 'APPROVAL_THRESHOLD_NOT_SET';
    END IF;
    IF p_amount_base IS NULL THEN
        RAISE EXCEPTION 'APPROVAL_AMOUNT_REQUIRED';
    END IF;
    -- 「10k 及以上归 CFO」—— Doc 1 的原话是"10k and above",所以是 >=
    RETURN CASE WHEN p_amount_base >= v_threshold THEN 2 ELSE 1 END;
END;
$function$;