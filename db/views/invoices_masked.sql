-- db/views/invoices_masked.sql
-- 遮蔽伴生视图:invoices 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:subtotal_usd → data.view_prices, tax_usd → data.view_prices, total_usd → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.finance.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

CREATE VIEW public.invoices_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    customer_id,
    issue_date,
    due_date,
    payment_terms_days,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN subtotal_usd
            ELSE NULL::numeric
        END AS subtotal_usd,
    tax_rate_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN tax_usd
            ELSE NULL::numeric
        END AS tax_usd,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN total_usd
            ELSE NULL::numeric
        END AS total_usd,
    status,
    void_reason,
    voided_at,
    voided_by,
    notes,
    terms_text,
    bill_to_snapshot,
    created_at,
    created_by
   FROM invoices
  WHERE has_permission('module.finance.view'::text);
