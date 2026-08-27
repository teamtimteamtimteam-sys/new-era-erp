-- db/views/purchase_order_payment_terms_masked.sql
-- 遮蔽伴生视图:purchase_order_payment_terms 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:fixed_amount_ccy → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.purchasing.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

-- CASHFLOW-1：加了 expected_date / _set_by / _set_at 三列。
-- ★ 这是【三件事一支迁移】的第三件 ★：ADD COLUMN + 列级 GRANT SELECT + 这张视图。
-- 列级 SELECT 授权不会自动延伸到后加的列，而 colgrant 的谓词是
-- (NOT granted AND NOT in_view) OR (has_view AND NOT in_view) —— 一张表一旦有了
-- _masked 伴生视图，它的每一列都得在视图里，授不授权都一样（WO-1a 为此连红两轮）。

CREATE VIEW public.purchase_order_payment_terms_masked WITH (security_invoker = off) AS
SELECT id,
    purchase_order_id,
    seq,
    label,
    percentage,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fixed_amount_ccy
            ELSE NULL::numeric
        END AS fixed_amount_ccy,
    trigger_event,
    due_date,
    notes,
    created_at,
    expected_date,
    expected_date_set_by,
    expected_date_set_at
   FROM purchase_order_payment_terms
  WHERE has_permission('module.purchasing.view'::text);
