-- db/views/invoice_document_totals.sql
-- 发票的【单据币种】小计/税/总额(INV-1)—— 客户要付的那几个数。
-- 由 invoice_lines.amount_ccy(生成列)汇总;发票行逐列不可改,所以推导值与
-- 开出去的那张纸永远一致,无须另存一份(PUR-1 存 PDF 字节是因为渲染会随代码变,
-- 数字不会)。invoices.*_base 是【本位币】,给账用的 —— 拿 currency 去标它们,
-- 正是 INV-1 修掉的错:线上两张已发出的发票各多报 1,440 / 336 USD。
-- 两道门与 invoices_masked 一致:module.finance.view 进模块、data.view_prices 看金额;
-- 无权者拿不到行(而不是拿到置空的数)—— 页面据此渲染受限。

CREATE VIEW public.invoice_document_totals WITH (security_invoker = off) AS
 SELECT i.id AS invoice_id,
    i.currency,
    COALESCE(sum(l.amount_ccy), 0::numeric) AS subtotal_ccy,
    round(COALESCE(sum(l.amount_ccy), 0::numeric) * i.tax_rate_pct / 100.0, 2) AS tax_ccy,
    COALESCE(sum(l.amount_ccy), 0::numeric) + round(COALESCE(sum(l.amount_ccy), 0::numeric) * i.tax_rate_pct / 100.0, 2) AS total_ccy
   FROM invoices i
     LEFT JOIN invoice_lines l ON l.invoice_id = i.id
  WHERE has_permission('module.finance.view'::text) AND has_permission('data.view_prices'::text)
  GROUP BY i.id, i.currency, i.tax_rate_pct;

COMMENT ON VIEW public.invoice_document_totals IS
    '发票的【单据币种】小计/税/总额(INV-1)—— 客户要付的那几个数。由 invoice_lines.amount_ccy 汇总而来;发票行逐列不可改,所以推导值与开出去的那张纸永远一致,无须另存一份。两道门与 invoices_masked 一致:module.finance.view 进模块、data.view_prices 看金额(整块视图挂在门后,而不是把数置空 —— 无权者拿不到行,页面据此渲染受限)。';

GRANT SELECT ON public.invoice_document_totals TO authenticated;
