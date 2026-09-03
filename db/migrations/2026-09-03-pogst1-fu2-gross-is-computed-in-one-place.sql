-- PO-GST-1-fu2(2026-09-03)· 含税额只在一个地方相加
--
-- ════════════════════════════════════════════════════════════════════════════
-- 委托 ①d:「如果 PDF 与屏幕的总额算自不同的地方,那是一个【发现】—— 说出来,
-- 并让它们读同一个来源。」
--
-- 【说出来的那一半】它们【本来就算自不同的地方】:
--   · PDF   读 po_document_data()(SECURITY DEFINER rpc,fixture 36 读的也是它);
--   · 屏幕  直接读 purchase_orders_masked / purchase_order_lines_masked。
-- 今天它们一致,靠的是【两条路碰巧落在同一列 estimated_total_ccy 上】——
-- 不是靠构造。**加了税之后,net 与 tax 仍然是同两列(所以不会漂),
-- 但 gross = net + tax 这一次加法会出现在两处。**
--
-- 【让它们读同一个来源的那一半】把 gross 放进遮蔽视图,于是:
--   · 屏幕 读 purchase_orders_masked.gross_total_ccy —— 【自己不做加法】;
--   · po_document_data 里那一次加法是给 PDF 的那一份;
--   · fixture 断言两者对同一张单【逐分相等】—— 而不是靠人去看两张纸。
--
-- 【为什么不把 gross 存成一列】存第三个数,就是给自己第三个会漂的地方:
-- 净额改了而 gross 没跟上,是一个看起来完全正常的错数。它是导出量,导出量不落库。
-- 【为什么 gross 不遮蔽成 NULL 而是随分量】它由两个受遮蔽的分量算出,
-- 任一为 NULL 时 CASE 已经让整个表达式为 NULL —— 遮蔽自然传导,不需要第二道 CASE。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS
 SELECT id, code, supplier_id, order_date, expected_delivery_date, currency,
        CASE WHEN has_permission('data.view_prices'::text) THEN fx_rate ELSE NULL::numeric END AS fx_rate,
        CASE WHEN has_permission('data.view_prices'::text) THEN estimated_total_ccy ELSE NULL::numeric END AS estimated_total_ccy,
    status, approval_status, approved_at, approved_by, incoterm, terms_text, notes,
    closed_at, cancelled_at, cancel_reason, deleted_at, created_at, created_by,
    updated_at, updated_by, deleted_by, delete_reason, cancelled_by, contract_id,
        CASE WHEN has_permission('data.view_prices'::text) THEN tax_total_ccy ELSE NULL::numeric END AS tax_total_ccy,
    -- PO-GST-1-fu2:含税额 —— 屏幕读这一列,【自己不做加法】。
    -- 遮蔽自然传导:分量为 NULL 时整个表达式就是 NULL。
    -- COALESCE(tax, 0):不带税的历史单据,含税额就等于净额。
        CASE WHEN has_permission('data.view_prices'::text)
             THEN estimated_total_ccy + COALESCE(tax_total_ccy, 0)
             ELSE NULL::numeric END AS gross_total_ccy,
    -- 这张单【算过税吗】—— NULL 的税额合计不是零税。屏幕靠它决定说哪句话。
    (tax_total_ccy IS NOT NULL) AS carries_tax
   FROM purchase_orders
  WHERE has_permission('module.purchasing.view'::text);

COMMIT;
