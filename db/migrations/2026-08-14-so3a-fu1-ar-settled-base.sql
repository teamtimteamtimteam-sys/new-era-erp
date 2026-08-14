-- db/migrations/2026-08-14-so3a-fu1-ar-settled-base.sql
-- SO-3a 收尾:应收账龄的【已结】那一列补上 —— 它从上线起就是空白
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【现象】/finance/receivables 的三列写着"金额 / 已结 / 未结,同为本位币",而
-- 页面读的是 r.settled_base —— ar_open_items 【没有这一列】。于是:
--     · 每一行的"已结"渲染成【空白】(formatMoneyBare(undefined) 返回空串);
--     · 每个客户的小计是 NaN(数字 + undefined)。
-- 线上唯一一张部分收款的单据 OUT-2026-0119(已结 1,129.03 USD @ 1.24 =
-- 1,400.00 本位币)因此在账龄页上看起来【一分钱都没收过】。
--
-- 【为什么不是把页面改成读 settled_ccy】那会把【单据币种】的数印进一列写着
-- 本位币的表格里 —— 正是 INV-1 修掉的那种错(当时线上两张发票各多报
-- 1,440 / 336)。列头没说谎,缺的是那个数。
-- 【也不是让页面去算 amount_base − open_base】两者数值上确实相等,但那是把
-- 一处推导搬进渲染层;同一张表的另外两列都由视图给出,这一列没有理由例外。
--
-- 【口径与同排两列一致】按【单据自己的入账汇率】折算:sale 支用 sr.fx_rate、
-- order 支用发票存下来的 fx_rate —— 与 open_base 逐字同一个乘数,所以
-- 金额 = 已结 + 未结 在每一行上都成立。
--
-- 【CREATE OR REPLACE,列追加在末尾】—— operations_now 建在本视图上,
-- 追加列不影响它(DROP 会连它一起带走)。
--
-- 镜像:db/views/ar_open_items.sql。行为断言:fixture 67 F 臂已断言两支的
-- open_base;本支补的是显示列,由手走的那一行渲染证明。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE VIEW public.ar_open_items WITH (security_invoker = off) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_base,
    sr.currency,
    round(sr.quantity * sr.unit_price, 2) AS amount_ccy,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_ccy,
    round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
    round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric)) * sr.fx_rate, 2) AS open_base,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - sr.sale_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    inv.invoice_id,
    inv.invoice_code,
    'sale'::text AS doc_kind,
    round(COALESCE(s.settled, 0::numeric) * sr.fx_rate, 2) AS settled_base
   FROM sales_records_masked sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
     LEFT JOIN LATERAL ( SELECT i.id AS invoice_id,
            i.code AS invoice_code
           FROM invoice_lines_masked il
             JOIN invoices_masked i ON i.id = il.invoice_id
          WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
         LIMIT 1) inv ON true
  WHERE round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) > 0::numeric
    AND has_permission('module.finance.view'::text)
UNION ALL
 SELECT NULL::uuid AS sales_record_id,
    o.code AS doc_code,
    o.customer_id,
    c.legal_name AS customer_name,
    o.issue_date AS sale_date,
    round(o.amount_ccy * o.fx_rate, 2) AS amount_base,
    o.currency,
    o.amount_ccy,
    o.settled_ccy,
    o.open_ccy,
    o.open_base,
    CURRENT_DATE - o.issue_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - o.issue_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - o.issue_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - o.issue_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    o.invoice_id,
    o.code AS invoice_code,
    'invoice'::text AS doc_kind,
    round(o.settled_ccy * o.fx_rate, 2) AS settled_base
   FROM order_invoice_open_all o
     LEFT JOIN customers c ON c.id = o.customer_id
  WHERE has_permission('module.finance.view'::text) AND has_permission('data.view_prices'::text);

COMMIT;
