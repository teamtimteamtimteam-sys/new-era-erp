-- db/functions/depreciation_months_elapsed.sql
-- CAPEX-1:直线折旧的【在役月数】—— 首月与末月按天折算。
--
-- ★【它是一次【纯提取】,不是一次改写】★
--   这段算术原本内联在 preview_depreciate_fixed_assets 里,只有一个调用方。
--   CAPEX-1 之后有两个:未锚定的那一支从【投用日】起算,锚定的那一支从
--   【锚点生效日】起算 —— 同一段算术,两个起点。
--   把它复制一份就是两份实现,而这段(首/末月按天折算)恰恰是最容易写错、
--   又最不容易被看出来的那一段。所以提取,而不是复制。
--
-- ★★【而"纯提取"这句话本身要被证明,不是被相信】★★
--   本仓库为「以为行为不变的改动」付过 SGD 56,532.48
--   (docs/fx-revaluation-misstatement-2026-07.md)。所以 fixture 144 的 A 臂
--   在别的臂跑之前,先拿几个【手算出来的】已知值断言这支函数 ——
--   把"这次重构是干净的"从一句信任变成一次测量。
--
-- 【口径,逐字保留自原实现】
--   · 起点晚于期末 → 0;
--   · 同一个月内 → (期末 − 起点 + 1) / 当月天数;
--   · 跨月 → 首月剩余天数占比 + 中间整月数 + 末月已过天数占比。
--   末月那一项用 EXTRACT(day FROM p_period_end),也就是【期末那一天的日号】——
--   月末日传进来时它就是整月。这一点看着别扭却是对的:这支例程只在月末被调用。

CREATE OR REPLACE FUNCTION public.depreciation_months_elapsed(p_start date, p_period_end date)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_m0 date;
    v_mn date;
BEGIN
    IF p_start IS NULL OR p_period_end IS NULL OR p_period_end < p_start THEN
        RETURN 0;
    END IF;
    v_m0 := date_trunc('month', p_start)::date;
    v_mn := date_trunc('month', p_period_end)::date;
    IF v_m0 = v_mn THEN
        RETURN (p_period_end - p_start + 1)::numeric
               / EXTRACT(day FROM (v_m0 + interval '1 month - 1 day'))::numeric;
    END IF;
    RETURN ((v_m0 + interval '1 month - 1 day')::date - p_start + 1)::numeric
               / EXTRACT(day FROM (v_m0 + interval '1 month - 1 day'))::numeric
           + (EXTRACT(year FROM age(v_mn, v_m0 + interval '1 month'))::numeric * 12
              + EXTRACT(month FROM age(v_mn, v_m0 + interval '1 month'))::numeric)
           + EXTRACT(day FROM p_period_end)::numeric
               / EXTRACT(day FROM (v_mn + interval '1 month - 1 day'))::numeric;
END;
$function$;

COMMENT ON FUNCTION public.depreciation_months_elapsed(date, date) IS
'CAPEX-1:直线折旧的在役月数,首/末月按天折算。**一次纯提取** —— 算术逐字取自
preview_depreciate_fixed_assets 的内联版本,提取是因为 CAPEX-1 之后有两个起点
(投用日 / 锚点生效日),而复制一份就是两份实现。
「纯提取」这句话由 fixture 144 的 A 臂用手算已知值证明,不靠相信 ——
本仓库为「以为行为不变的改动」付过 SGD 56,532.48。';
