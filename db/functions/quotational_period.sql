CREATE OR REPLACE FUNCTION public.quotational_period(p_base_date date, p_qp_months integer)
 RETURNS TABLE(qp_from date, qp_to date)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- PRICE-1:M+n 的计价期 = 基准月往后第 n 个【整月】的自然月首尾。
    -- 【为什么算而不是存】把 qp_from/qp_to 存进 contract_pricing_terms,就是同一个
    -- 事实的第二份,而它会与 base_event / qp_months 漂开(本仓库为"两份实现"付过四次账)。
    SELECT (date_trunc('month', p_base_date) + make_interval(months => p_qp_months))::date,
           (date_trunc('month', p_base_date) + make_interval(months => p_qp_months)
              + interval '1 month' - interval '1 day')::date
    WHERE p_base_date IS NOT NULL AND p_qp_months IS NOT NULL;
$function$;

COMMENT ON FUNCTION public.quotational_period(date, integer) IS
    'PRICE-1:M+n 的计价期 = 基准月往后第 n 个【整月】的自然月首尾。**算,不存** —— 把 qp_from/qp_to 存进 contract_pricing_terms 就是同一个事实的第二份,而它会与 base_event / qp_months 漂开(本仓库为「两份实现在写下来那天一致、之后悄悄分开」付过四次账)。n 允许 0(= 基准月本身)。';
