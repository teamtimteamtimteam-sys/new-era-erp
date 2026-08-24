-- db/views/invoice_lines_masked.sql
-- 遮蔽伴生视图:invoice_lines 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:amount_base → data.view_prices, unit_price → data.view_prices,
--             tax_base → data.view_prices(GST-2;tax_code 与 tax_rate_pct 【不遮】——
--             前者是分类不是钱,后者是 IRAS 公布的法定税率,遮掉只会让人把
--             "有税码没税率"读成"这一行没有税")
--             amount_ccy → data.view_prices(INV-1,列在末尾:CREATE OR REPLACE 只能追加,
--             而 ar_open_items 与 invoice_status 建在本视图上,DROP 会连它们一起带走)
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.finance.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.
CREATE VIEW public.invoice_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    invoice_id,
    sales_record_id,
    line_no,
    description,
    quantity,
    unit,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    invoice_voided,
    created_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy,
    sales_order_line_id,
    tax_code,
    tax_rate_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN tax_base
            ELSE NULL::numeric
        END AS tax_base
   FROM invoice_lines
  WHERE has_permission('module.finance.view'::text);;