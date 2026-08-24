-- db/functions/tax_rate_for.sql
-- GST-1:按【单据自己那一天】解析税码的税率。
-- **没有那一天的税率就按名拒(TAX_RATE_NOT_FOUND),不取最近的一条、不回退。**
-- 与 FX 那条规矩逐字同源:编一个税率与编一个汇率是同一种谎。
-- 税率之所以能按日期解析,是因为它挂在 tax_rates 的生效期间上而不是一个标量设置上
-- —— 一个标量表达不了"历史单据留住当时那一个"。

CREATE OR REPLACE FUNCTION public.tax_rate_for(p_code text, p_date date)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_rate numeric;
BEGIN
    IF p_code IS NULL THEN RAISE EXCEPTION 'TAX_CODE_REQUIRED'; END IF;
    IF p_date IS NULL THEN RAISE EXCEPTION 'TAX_DATE_REQUIRED|%', p_code; END IF;
    IF NOT EXISTS (SELECT 1 FROM tax_codes WHERE code = p_code) THEN
        RAISE EXCEPTION 'TAX_CODE_UNKNOWN|%', p_code;
    END IF;
    SELECT r.rate_pct INTO v_rate FROM tax_rates r
     WHERE r.tax_code = p_code
       AND p_date >= r.effective_from
       AND (r.effective_to IS NULL OR p_date <= r.effective_to);
    IF v_rate IS NULL THEN
        -- 【与 FX 同一条】没有那一天的税率就拒绝,不假设、不取最近的一条。
        RAISE EXCEPTION 'TAX_RATE_NOT_FOUND|%|%', p_code, p_date;
    END IF;
    RETURN v_rate;
END;
$function$;