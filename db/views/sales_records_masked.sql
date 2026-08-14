-- db/views/sales_records_masked.sql
-- 遮蔽伴生视图:sales_records 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:amount_base → data.view_prices, fx_rate → data.view_prices, unit_price → data.view_prices,
--   price_provenance → data.view_prices(SAL-A:出处里有 USD 单价与汇率,与 unit_price 同档)
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.finance.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.
--
-- 【SO-2b:movement_id 不在了】那一列被 DROP 掉了 —— 一次销售可能对应【多条】
-- 流水腿(跨库位排空),而一个单值外键只装得下第一条。腿在
-- sales_record_movements 里,一条一行。本视图是它唯一的结构性读者,所以这一刀
-- 要 DROP + CREATE 它(以及跟着它的 ar_open_items / operations_now),
-- 而不是 CREATE OR REPLACE —— 后者改不了列集。

CREATE VIEW public.sales_records_masked WITH (security_invoker = off) AS
 SELECT id,
    output_batch_id,
    customer_id,
    quantity,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    sale_date,
    notes,
    created_at,
    created_by,
    cogs_entry_id,
    price_source,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN price_provenance
            ELSE NULL::jsonb
        END AS price_provenance,
    sales_order_line_id
   FROM sales_records
  WHERE has_permission('module.finance.view'::text);
