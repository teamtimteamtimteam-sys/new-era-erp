-- db/views/payment_term_template_lines_masked.sql
-- ★ ROLE-1 Batch 4a(2026-09-25,Tim 的 Q9 线):本视图是【采购那一侧】的价格 —— 遮蔽码从 data.view_prices
--   换成 data.view_purchase_prices(今天持 view_prices 的每一个角色一并拿到它,仓库只拿它)。
-- 遮蔽伴生视图:payment_term_template_lines 的每一列都在,敏感列按 has_permission() 置空。
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

CREATE VIEW public.payment_term_template_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    template_id,
    seq,
    label,
    percentage,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN fixed_amount_ccy
            ELSE NULL::numeric
        END AS fixed_amount_ccy,
    trigger_event,
    days_offset,
    notes,
    created_at
   FROM payment_term_template_lines
  WHERE has_permission('module.purchasing.view'::text);
