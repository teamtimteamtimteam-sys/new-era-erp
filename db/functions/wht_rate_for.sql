CREATE OR REPLACE FUNCTION public.wht_rate_for(p_nature text, p_date date)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_rate numeric;
BEGIN
    -- 【SECURITY DEFINER 的权限检查】这支函数按 definer 跑,所以它必须自己问
    -- 调用者是谁 —— 一支不问的 definer 函数就是一条绕过 RLS 的路。
    -- 这个形状在本仓库已经【上线过两次、被闸抓住两次】,不再犯第三次。
    PERFORM require_permission('module.finance.view');
    IF p_nature IS NULL THEN RAISE EXCEPTION 'WHT_NATURE_REQUIRED'; END IF;
    IF p_date IS NULL THEN RAISE EXCEPTION 'WHT_DATE_REQUIRED|%', p_nature; END IF;
    IF NOT EXISTS (SELECT 1 FROM wht_natures WHERE code = p_nature) THEN
        RAISE EXCEPTION 'WHT_NATURE_UNKNOWN|%', p_nature;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM wht_natures WHERE code = p_nature AND is_active) THEN
        RAISE EXCEPTION 'WHT_NATURE_INACTIVE|%', p_nature;
    END IF;
    SELECT r.rate_pct INTO v_rate FROM wht_rates r
     WHERE r.nature = p_nature
       AND p_date >= r.effective_from
       AND (r.effective_to IS NULL OR p_date <= r.effective_to);
    IF v_rate IS NULL THEN
        -- 【与 FX、与 GST 同一条】没有那一天的税率就拒绝,不假设、不取最近的一条。
        RAISE EXCEPTION 'WHT_RATE_NOT_FOUND|%|%', p_nature, p_date;
    END IF;
    RETURN v_rate;
END;
$function$
;
