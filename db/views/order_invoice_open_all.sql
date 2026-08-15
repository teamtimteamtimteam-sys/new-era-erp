-- db/views/order_invoice_open_all.sql
-- SO-3a:订单流发票的【开放余额】—— 敞口与应收的唯一一处内层推导(基视图)。
--
-- NOTE: introduced by db/migrations/2026-08-14-so3a-order-flow-billing.sql.
--
-- 【为什么要有这一层】选项 C 之下,订单流发票在开票当刻就过账(借 1100 应收 /
-- 贷 2500 合同负债),于是"客户欠多少"多了第二个来源。这个数有【两个消费者】:
--     ar_open_items(应收账龄的第二支)
--     customer_ar_exposure_base(信用敞口的第二项)
-- 面板上显示的余额与拒绝销售/开票的那道闸,必须是【同一个数】—— 两处各写一遍
-- 就是两份会漂开的实现(预览规矩的应收版)。所以推导只写在这里,两个消费者都
-- 引用它;fixture 67 的目录断言钉住"都在引用"这件事。
--
-- 【口径】只算 kind='order' 且在册(issued)的发票;金额 = Σ 明细行 amount_ccy
-- (生成列,发票行逐列不可改,推导值与开出去的那张纸永远一致 ——
-- invoice_document_totals 的同一条理由);已结 = 指向发票本身的核销行
-- (payment_allocations.invoice_id,只计 posted 收款 —— 冲销收款自动失效,
-- 与 ar_open_items 的销售支同口径);open_base 按发票【存下来的】fx_rate 折算 ——
-- 那是从订单抄来的入账汇率,结算解除用的也是它(FIN-27 一族:抄下来的承诺,
-- 不是开屏时现查的行情)。
--
-- 【客户端读不到本视图】REVOKE SELECT —— 它不带 has_permission 的门,读得到它
-- 就等于绕过 module.finance.view 直接读全部客户的应收(stock_class_violations_all
-- 的同一条)。两个消费者一个是属主视图(视图引用视图走属主替换)、一个是
-- SECURITY DEFINER 函数(以属主身份读),都够得着。

CREATE VIEW public.order_invoice_open_all WITH (security_invoker = off) AS
 SELECT invoice_id,
    code,
    customer_id,
    issue_date,
    due_date,
    currency,
    fx_rate,
    amount_ccy,
    settled_ccy,
    open_ccy,
    open_base,
    credited_ccy,
    credited_base
   FROM order_invoice_balance_all b
  WHERE open_ccy > 0::numeric;

COMMENT ON VIEW public.order_invoice_open_all IS
    'SO-3a:订单流发票的开放余额 ——【敞口与应收的唯一一处内层推导】。两个消费者:ar_open_items(账龄第二支)与 customer_ar_exposure_base(敞口第二项);面板显示的余额与拒绝的那道闸必须是同一个数,所以推导只写这一遍(fixture 67 目录断言钉住)。口径:kind=''order'' 且 issued;金额 = Σ 明细行 amount_ccy(生成列);已结 = payment_allocations.invoice_id 上 posted 收款的核销;open_base 按发票存下来的 fx_rate(从订单抄来的入账汇率)。【客户端读不到】:REVOKE SELECT —— 不带门,读得到就等于绕过 module.finance.view 读全库应收。';

REVOKE SELECT ON public.order_invoice_open_all FROM authenticated, anon;
