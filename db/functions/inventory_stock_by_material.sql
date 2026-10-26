-- db/functions/inventory_stock_by_material.sql
-- TABLE-FEATURES-2(Tim 2026-10-26:「库存估值合计条由库算的合计取代」):/inventory 台账【每一行】的数 —— 一种物料一行。
--   ★ 存在的理由:表尾合计(list_totals_inventory)由库算,而行此前在 JS 里算(app/inventory/page.tsx 的 rowsByMaterial)。
--     两份实现会在某一天对不上(AGENTS.md「A screen that previews a posting ASKS the database」),于是行也搬进库:
--     页面画本函数的行,list_totals_inventory 加本函数的列 —— 一份实现,两个调用方。
--   ★ 顺带去掉七次无序、无分页的整表读(PostgREST 1,000 行上限处的子集是任意的)。
-- 【批次集合】(与搬家前 page.tsx 的读法逐项相同):
--   * 进料:inbound_batch_valuation 里 remaining_qty > 0 的行(该视图已去掉 deleted_at 的批次)。
--     ★ 物料被删了的进料批次【照算】—— 页面一直把它们画成名为「—」的一行(物料名查表过滤 deleted_at,估值视图不过滤);
--       合计跟着行走。线上 2026-10-26 这样的批次为 0。
--   * 产出:output_batch_lookup 里 deleted_at IS NULL 且 remaining_qty > 0 的行(物料被删的同样照算)。
-- 【每一列的规则】
--   * inbound_stock / output_stock = Σ remaining_qty;priced_qty = Σ 进料 remaining_qty where NOT unpriced(加权均价的分母)。
--   * unit / mixed_unit:这一物料所有在库批次的单位只有一种 → 那一种;不止一种 → mixed_unit = true,unit = NULL(页面画「混合」)。
--   * stock_value(本位币)= Σ remaining_qty × landed_unit_cost,只加 landed_unit_cost 非 NULL 的批次;一张都没有 → NULL。
--     没有 data.view_prices 时视图把 landed_unit_cost 遮成 NULL,于是整列 NULL —— 是否「受限」由调用方按权限说,不由 NULL 倒推。
--   * cost_value(本位币)= Σ remaining_qty × 产出腿 unit_cost_base(processing_output_lookup,同样按 data.view_prices 遮蔽;
--     从未分摊的腿也是 NULL),只加非 NULL 的;一张都没有 → NULL。一个批次至多一条产出腿(取非 NULL 的那一条)。
--   * market_value(USD,不折算 —— lib/valuation.ts 抬头)= Σ remaining_qty × 每公斤市价;
--     每公斤市价 = Σ 有价金属 (content_pct/100 × price_usd_per_tonne/1000)(output_batch_metal_lookup);
--     价 = 每个金属 price_date 最大的一条 metal_prices(deleted_at IS NULL、price_date ≤ 今天的 UTC 日期 —— 与页面原来的
--     new Date().toISOString().slice(0,10) 同一个「今天」,也与 /inventory/output/[materialId] 同一个),
--     且 price_index 等于 pricing_settings.default_metal_index(NULL = 未标注指数的那条序列,IS NOT DISTINCT FROM)。
--     ★ 部分计价:一批里没有价的金属【跳过】,只要有一种金属有价,这一批就有市价(lib/valuation.ts marketValuePerKg 同一规则);
--       一种都没有 → 这一批不计入;一种物料一批都没有 → NULL。单位假定是 kg(不检查,与 JS 同)。不遮蔽(金属价与含量都不是价格)。
--   * 不在库里四舍五入:每一格的显示由页面格式化;合计在 list_totals_inventory 里对精确和取 2 位。
-- 【门】require_permission('module.inventory.view') —— 页面守卫 requireModule(MOD.inventory) 的码。INVOKER:读的就是读者自己读得到的那几张视图。
-- ★ 同一条市价规则在 TS 里还有一份:lib/valuation.ts(/inventory/output/[materialId] 钻取页用)。改规则两处一起改。
CREATE OR REPLACE FUNCTION public.inventory_stock_by_material()
 RETURNS TABLE(material_id uuid, unit text, mixed_unit boolean, inbound_stock numeric, output_stock numeric, priced_qty numeric, stock_value numeric, cost_value numeric, market_value numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_today date := (now() AT TIME ZONE 'UTC')::date;
    v_index text;
BEGIN
    PERFORM require_permission('module.inventory.view');
    SELECT ps.default_metal_index INTO v_index FROM pricing_settings ps WHERE ps.id;

    RETURN QUERY
    WITH price AS (
        SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne
          FROM metal_prices mp
         WHERE mp.deleted_at IS NULL
           AND mp.price_date <= v_today
           AND mp.price_index IS NOT DISTINCT FROM v_index
         ORDER BY mp.metal, mp.price_date DESC
    ), per_kg AS (
        SELECT obm.output_batch_id,
               sum(obm.content_pct / 100 * pr.price_usd_per_tonne / 1000) AS usd_per_kg
          FROM output_batch_metal_lookup obm
          JOIN price pr ON pr.metal = obm.metal
         GROUP BY obm.output_batch_id
    ), batch AS (
        SELECT ib.material_id, ib.unit,
               ib.remaining_qty AS inbound_qty, 0::numeric AS output_qty,
               CASE WHEN NOT ib.unpriced THEN ib.remaining_qty ELSE 0 END AS priced_qty,
               ib.remaining_qty * ib.landed_unit_cost AS stock_value,
               NULL::numeric AS cost_value,
               NULL::numeric AS market_value
          FROM inbound_batch_valuation ib
         WHERE ib.remaining_qty > 0
        UNION ALL
        SELECT ob.material_id, ob.unit,
               0, ob.remaining_qty,
               0,
               NULL,
               ob.remaining_qty * leg.unit_cost_base,
               ob.remaining_qty * pk.usd_per_kg
          FROM output_batch_lookup ob
          LEFT JOIN LATERAL (SELECT pol.unit_cost_base FROM processing_output_lookup pol
                              WHERE pol.output_batch_id = ob.id AND pol.unit_cost_base IS NOT NULL
                              LIMIT 1) leg ON true
          LEFT JOIN per_kg pk ON pk.output_batch_id = ob.id
         WHERE ob.deleted_at IS NULL
           AND ob.remaining_qty > 0
    )
    SELECT b.material_id,
           CASE WHEN count(DISTINCT b.unit) = 1 THEN min(b.unit) END,
           count(DISTINCT b.unit) > 1,
           sum(b.inbound_qty),
           sum(b.output_qty),
           sum(b.priced_qty),
           sum(b.stock_value),
           sum(b.cost_value),
           sum(b.market_value)
      FROM batch b
     GROUP BY b.material_id;
END;
$function$;