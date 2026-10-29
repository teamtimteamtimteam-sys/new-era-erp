-- db/views/sales_settlements_masked.sql
-- GOLIVE-1 第 12 行(Tim 2026-10-25 TABLE-EXPORT-3c Q3 · 2026-10-29 Q9):遮蔽伴生视图 —— sales_settlements 的每一列都在,钱按 data.view_prices 置空。
--   遮蔽的列:metal_value_usd · refining_charge_usd · penalty_usd · amount_usd · breakdown(逐项拆解里有单价与金额)· terms_snapshot(冻结的条款副本里有费率)。
--   结算是【销售那一侧】的钱(客户合同),所以只问 data.view_prices。重量、口径、指针与时间不遮。
-- 【属主权限】把表的读策略(module.customers.view)原样写回视图体 —— 属主绕过行级策略,漏写这一句就把行交给了每一个人。
--   两个判断都写成按语句求一次的 (SELECT has_permission(…))(CHAIN-WALK-COST 那条规矩)。
--
-- NOTE: introduced by db/migrations/2026-10-29-golive-1.sql.

CREATE VIEW public.sales_settlements_masked WITH (security_invoker = off) AS
 SELECT
    id,
    sales_order_id,
    output_batch_id,
    assay_result_id,
    settling_party_used,
    weight_basis_used,
    gross_weight_kg,
    moisture_pct,
    settlement_weight_kg,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN metal_value_usd
            ELSE NULL::numeric
        END AS metal_value_usd,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN refining_charge_usd
            ELSE NULL::numeric
        END AS refining_charge_usd,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN penalty_usd
            ELSE NULL::numeric
        END AS penalty_usd,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN amount_usd
            ELSE NULL::numeric
        END AS amount_usd,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN breakdown
            ELSE NULL::jsonb
        END AS breakdown,
        CASE
            WHEN ( SELECT has_permission('data.view_prices'::text) AS has_permission) THEN terms_snapshot
            ELSE NULL::jsonb
        END AS terms_snapshot,
    superseded_by,
    computed_at,
    computed_by
   FROM sales_settlements
  WHERE ( SELECT has_permission('module.customers.view'::text) AS has_permission);

REVOKE ALL ON public.sales_settlements_masked FROM authenticated, anon;
GRANT SELECT ON public.sales_settlements_masked TO authenticated;
