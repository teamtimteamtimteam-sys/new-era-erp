-- db/functions/calculate_metal_price_internal.sql
-- 计价算术的【内部算子】:DEFINER,不做权限检查,EXECUTE 已对 PUBLIC/authenticated/anon 收回。
-- 它只能从别的函数体内被调用(那时以属主身份运行),不能当作 RPC 直接问出一个价格来。
--
-- 为什么要拆:calculate_metal_price 既是采购页面的界面入口(必须查 data.view_prices),
-- 又被 apply_assay_result 内部调用(仓储/运营在跑,他们没有这个码)。只加一道检查会让
-- 化验应用当场失败,所以把「算」与「谁能问」分开 —— 检查留在同名的入口函数里。
--
-- 【注意】函数默认对 PUBLIC 授予 EXECUTE,只收回 authenticated/anon 是不够的。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.
--
-- FIN-10(2026-08-05):日期不再有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。
-- 默认成今天永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关,
-- 这条路径专门奖励留空。要求由函数自己声明,而不是靠调用方自觉。
-- 详见 db/migrations/2026-08-05-fin10-no-default-posting-dates.sql。
--
-- FIN-27(2026-08-07):算术搬进 calculate_metal_price_from_terms(条款 → 价),
-- 本函数只剩"喂它【活公式】的条款"这一件事。结算侧喂的是承诺副本的条款
-- (pricing_terms_of_commitment)。【同一份算术,两个调用方,两种条款来源】——
-- 报价按新条款、结算按承诺条款,而两者不可能各算各的。
-- 参见 db/migrations/2026-08-07-fin27-pricing-terms-commitment.sql。

CREATE OR REPLACE FUNCTION public.calculate_metal_price_internal(p_formula_id uuid, p_metals jsonb, p_quantity_kg numeric, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 报错次序与 FIN-27 之前一致:先日期,再公式,再数量/金属。
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    RETURN calculate_metal_price_from_terms(
        pricing_terms_of_formula(p_formula_id), p_metals, p_quantity_kg, p_reference_date);
END;
$function$;