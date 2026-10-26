-- db/functions/list_totals_fixed_assets.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1):/finance/assets 台账那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
--   (下面那张折旧预览已经有库算的合计行 —— preview_depreciate_fixed_assets 的 total_delta —— 不归本函数。)
-- 【筛选】台账没有筛选,一次读全 fixed_assets(app/finance/assets/page.tsx:102);已处置的资产照样列着,所以照样计入。
-- 【四个合计】
--   'cost'     = cost_ccy,按行上的 currency(原币,每个币种一行);
--   'costBase' = cost_base,本位币;
--   'accum'    = Σ fixed_asset_depreciation.amount_base,本位币;
--   'nbv'      = Σ 每一行的 round(cost_base − 该资产累计折旧, 2),本位币 —— 与那一行的算法逐字同一个
--                (page.tsx:184/196:累计按资产先加、两位小数,再 cost_base − 累计 取两位)。
--   本位币那三列的 currency 给 (SELECT code FROM currencies WHERE is_base)。
-- 【净额】cost_base 本身已是未冲销成本明细之和(fixed_assets.sql 抬头);折旧行只追加、没有冲销镜像 —— 照行上的数加总。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(assets/page.tsx:92),
--   与 fixed_assets / fixed_asset_depreciation 两张表的 SELECT 策略同一个码。invoker;没有金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_fixed_assets()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base text := (SELECT c.code FROM currencies c WHERE c.is_base);
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    WITH per_asset AS (
        SELECT a.currency::text AS ccy, a.cost_ccy, a.cost_base,
               COALESCE((SELECT round(sum(d.amount_base), 2) FROM fixed_asset_depreciation d WHERE d.asset_id = a.id), 0) AS accum
          FROM fixed_assets a
    ), cells AS (
        SELECT p.ccy AS ccy, 1 AS ord, 'cost'::text AS m, p.cost_ccy AS amt FROM per_asset p
        UNION ALL SELECT v_base, 2, 'costBase', p.cost_base FROM per_asset p
        UNION ALL SELECT v_base, 3, 'accum', p.accum FROM per_asset p
        UNION ALL SELECT v_base, 4, 'nbv', round(p.cost_base - p.accum, 2) FROM per_asset p
    )
    SELECT ''::text, c.ccy, c.m, round(sum(c.amt), 2), false
      FROM cells c
     GROUP BY c.ccy, c.ord, c.m
     ORDER BY (c.ccy = v_base) DESC, c.ccy, c.ord;
END;
$function$;