-- db/functions/list_totals_inventory.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1 与「库存估值合计条由库算的合计取代」):/inventory 台账的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【集合】正是台账的行:inventory_stock_by_material() 的每一行(批次集合与每一列的规则写在那支函数的抬头里)。
--   页面没有筛选(快照页,既定约定),所以没有参数。合计 = 每一列在所有物料上的精确和,取 2 位
--   (每一行在屏幕上各自四舍五入,所以表尾与「屏幕上各行之和」可能差几分 —— 表尾是对的那个)。
-- 【三个合计,两个币种】measure:
--   * stockValue  —— 本位币(currencies.is_base)。
--   * costValue   —— 本位币。
--   * marketValue —— USD(metal_prices.price_usd_per_tonne,不折算;lib/valuation.ts 抬头)。币种字面量写在这里而不是交给页面
--     (fixedCurrency):它是这一列的单位,烤在它所乘的那一列的列名里(该表没有币种列),与算它的那支函数放在一起。
--   avgPrice 是价,不合计(裁定:价格类列没有合计)。
-- 【受限】stockValue / costValue:NOT has_permission('data.view_prices') —— 两列被同一条权限遮蔽(inbound_batch_valuation_rows、
--   processing_output_lookup),所以按读者判,不按行数判;受限时 total 为 NULL,而且即使一行都没有也照样各给一行;currency 仍给本位币 —— 列的币种是固定的(列头写着),说出它不泄露任何数,表尾因此仍是「本位币一行、USD 一行」。
--   marketValue 不遮蔽,restricted 恒为 false。
--   ★ 有权限的读者看到的 NULL 是真的「没有」(未计价的批、从未分摊的产出腿),不算受限 —— 与行上那根「—」同一个意思。
-- 【空集】某一列在所有物料上都是 NULL(没有一批计入)且读者不受限 → 那一列不出行(页面不画那一格)。
-- 【门】require_permission('module.inventory.view') —— 页面守卫 requireModule(MOD.inventory)(lib/modules.ts)。INVOKER。
CREATE OR REPLACE FUNCTION public.list_totals_inventory()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base text;
    v_prices boolean;
BEGIN
    PERFORM require_permission('module.inventory.view');
    v_prices := has_permission('data.view_prices');
    SELECT c.code::text INTO v_base FROM currencies c WHERE c.is_base;

    RETURN QUERY
    WITH r AS (
        SELECT sum(s.stock_value) AS stock_value, sum(s.cost_value) AS cost_value, sum(s.market_value) AS market_value
          FROM inventory_stock_by_material() s
    )
    SELECT ''::text, v_base, 'stockValue'::text, round(r.stock_value, 2), false
      FROM r WHERE v_prices AND r.stock_value IS NOT NULL
    UNION ALL
    SELECT ''::text, v_base, 'stockValue'::text, NULL::numeric, true
     WHERE NOT v_prices
    UNION ALL
    SELECT ''::text, v_base, 'costValue'::text, round(r.cost_value, 2), false
      FROM r WHERE v_prices AND r.cost_value IS NOT NULL
    UNION ALL
    SELECT ''::text, v_base, 'costValue'::text, NULL::numeric, true
     WHERE NOT v_prices
    UNION ALL
    SELECT ''::text, 'USD'::text, 'marketValue'::text, round(r.market_value, 2), false
      FROM r WHERE r.market_value IS NOT NULL;
END;
$function$;