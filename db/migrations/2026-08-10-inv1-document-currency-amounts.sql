-- INV-1:发票按【单据币种】开出来 —— 客户手里那张纸上的数,必须是客户要付的数
--
-- 走查发现:发票页与【发票 PDF】都拿 invoices.currency 去标 *_base 的数。
-- 这两类列是两回事,镜像里写得清清楚楚:
--     invoices.subtotal_base / tax_base / total_base、invoice_lines.amount_base
--         —— 本位币(currencies.is_base),给账用的;
--     invoices.currency、invoice_lines.unit_price
--         —— 单据币种(= 销售记录自己的币种;create_invoice 混币直接 MIXED_CURRENCY 拒)。
-- 于是 PDF 上印着 `Total (USD) 7,440.00`,而客户实际欠的是 500 × 12 = 6,000.00 USD。
-- 线上已发出的两张就是这样:INV-2026-0004 多报 1,440 USD(24%),
-- INV-2026-0003 多报 336 USD;INV-2026-0002 侥幸对上,只因它的 fx_rate 恰好是 1
-- (FIN-0 翻本位币之前开的)。同一行里 unit_price 是单据币、amount 是本位币,
-- 数量 × 单价 ≠ 金额 —— 一张自己都对不上账的发票。
--
-- 【修法:不是改标签,是补上那个数】客户面的金额从来就该是单据币种的,它此前
-- 根本不存在于任何地方。所以补出来,并且【标它自己是什么】:
--   * invoice_lines.amount_ccy —— 生成列(GENERATED ALWAYS AS … STORED):
--     round(quantity * unit_price, 2)。纯粹是同一行两列的乘法,【不经过汇率】,
--     所以不可能漂;既有行由 Postgres 当场算出,不需要回填,也无从回填错。
--   * invoice_document_totals 视图 —— 单据币种的小计/税/总额。发票行【逐列不可改】
--     (invoice_lines 的守卫触发器),所以推导出来的总额与"当时开出去的"永远一致,
--     不需要再存一份(PUR-1 存字节是因为 PDF 会随代码变,数字不会)。
--
-- 【本位币的数一个都没动】账仍按 *_base 记:AR、收入、核销、报表全部不变。
-- 变的只是"给客户看的那一列现在有了自己的数和自己的标签"。
--
-- 遮蔽表加列的规矩(AGENTS.md):amount_ccy 是钱 → 【不进列授权清单】,
-- 只经 invoice_lines_masked 读,gate 的 colgrant 行会盯着。
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 行金额,单据币种(生成列 —— 无汇率、无回填、不可能与 unit_price 漂开)
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.invoice_lines
    ADD COLUMN amount_ccy numeric
    GENERATED ALWAYS AS (round(quantity * unit_price, 2)) STORED;

COMMENT ON COLUMN public.invoice_lines.amount_ccy IS
    '行金额,【单据币种】(INV-1)。= round(quantity × unit_price, 2),不经汇率,所以与 unit_price 天然同币种。客户账单上那一列印的就是它;amount_base 是同一行的【本位币】金额,给账用 —— 两者只在汇率为 1 时相等,把后者标成前者正是 INV-1 修掉的错。';

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 单据币种的小计 / 税 / 总额(推导,不另存 —— 发票行逐列不可改)
-- ════════════════════════════════════════════════════════════════════════════
-- 税:按发票自己抄下来的 tax_rate_pct 算在单据币种上(与 create_invoice 在本位币
-- 上的算法同构:先小计后乘率再四舍五入到分)。公司尚未登记 GST,税率恒 0 ——
-- 但算式写对了,登记那天不必再想一遍。
CREATE VIEW public.invoice_document_totals WITH (security_invoker = off) AS
SELECT i.id AS invoice_id,
       i.currency,
       COALESCE(sum(l.amount_ccy), 0) AS subtotal_ccy,
       round(COALESCE(sum(l.amount_ccy), 0) * i.tax_rate_pct / 100.0, 2) AS tax_ccy,
       COALESCE(sum(l.amount_ccy), 0)
           + round(COALESCE(sum(l.amount_ccy), 0) * i.tax_rate_pct / 100.0, 2) AS total_ccy
FROM invoices i
LEFT JOIN invoice_lines l ON l.invoice_id = i.id
WHERE has_permission('module.finance.view'::text)
  AND has_permission('data.view_prices'::text)
GROUP BY i.id, i.currency, i.tax_rate_pct;

COMMENT ON VIEW public.invoice_document_totals IS
    '发票的【单据币种】小计/税/总额(INV-1)—— 客户要付的那几个数。由 invoice_lines.amount_ccy 汇总而来;发票行逐列不可改,所以推导值与开出去的那张纸永远一致,无须另存一份。两道门与 invoices_masked 一致:module.finance.view 进模块、data.view_prices 看金额(整块视图挂在门后,而不是把数置空 —— 无权者拿不到行,页面据此渲染受限)。';

GRANT SELECT ON public.invoice_document_totals TO authenticated;

COMMIT;
