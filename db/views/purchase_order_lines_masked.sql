-- db/views/purchase_order_lines_masked.sql
-- 遮蔽伴生视图:purchase_order_lines 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:estimated_amount_ccy → data.view_prices, estimated_unit_price → data.view_prices,
--             price_provenance → data.view_prices, tax_amount_ccy → data.view_prices(PO-GST-1)
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.purchasing.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.
-- FIN-26:price_source 透出(不敏感);price_provenance 含逐金属价格 → 随 data.view_prices。

-- EQP-1a(2026-08-20):追加 asset_id(在末尾)—— 与加列、加列清单授权同一支迁移。
CREATE VIEW public.purchase_order_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    line_no,
    material_id,
    quantity,
    unit,
    pricing_formula_id,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_unit_price
            ELSE NULL::numeric
        END AS estimated_unit_price,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_amount_ccy
            ELSE NULL::numeric
        END AS estimated_amount_ccy,
    expected_assay,
    notes,
    created_at,
    created_by,
    price_source,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN price_provenance
            ELSE NULL::jsonb
        END AS price_provenance,
    asset_id,
    -- PROC-1B-iii fu1:遮蔽表加一列 = 三件事(列 + 列级授权 + 本视图)。
    -- 【不遮蔽,原样透出】它是工艺路由要用的事实,不是钱、不是个人信息。
    deep_discharge_judgement_code,
    -- PO-GST-1(2026-09-03):税码与税率【不遮蔽】—— 一个是分类,一个是法定税率,
    -- 都不是钱;税【额】是钱,而且从被扣住的净额推得出来,所以随 data.view_prices,
    -- 与 estimated_amount_ccy 同一扇门。
    tax_code,
    tax_rate_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN tax_amount_ccy
            ELSE NULL::numeric
        END AS tax_amount_ccy
   FROM purchase_order_lines
  WHERE has_permission('module.purchasing.view'::text);

