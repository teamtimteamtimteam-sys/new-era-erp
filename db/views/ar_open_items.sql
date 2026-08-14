-- db/views/ar_open_items.sql
-- AR 开放余额(应收账龄):每张未结清 sales_record 一行。
-- 结清额只计 status='posted' 收款单的核销行 —— 冲销(reversed)收款的核销自动失效。
-- cut 2a 起增加 invoice_id / invoice_code:经 invoice_lines 反查该销售所挂的【在册】
-- 发票(作废的不算),未开票的销售这两列为 NULL。其余列全部保名保义。
--
-- 【SO-3a-fu1:settled_base —— 补上一列,而不是让页面自己减】本视图一直给出
-- amount_base / open_base 两个【本位币】数,却只有 settled_ccy 一个【单据币种】的
-- 已结额。应收账龄页的三列写着"同为本位币",于是它读了一个【根本不存在】的
-- settled_base:整列渲染成空白、客户小计渲染成 NaN,从上线起如此。
-- 修法【不是】把页面改成读 settled_ccy —— 那会把单据币种的数印进本位币那一列,
-- 正是 INV-1 修掉的那种错(线上两张发票各多报 1,440 / 336)。也不是让页面去减
-- amount_base − open_base:那是把一处推导搬进渲染层。补一列,口径与同排两列一致
-- (都按单据自己的入账汇率折算),三列从此真的是同一种钱。
-- 【属主权限】(OPS-14 起;原为 security_invoker = on)—— 见下方 note。
-- NOTE: introduced by db/migrations/2026-07-06-phase3-cut3a-payments.sql;
-- invoice 两列由 db/migrations/2026-07-31-phase4-cut2a-invoices.sql 追加(DROP+CREATE)。

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的。【OPS-14 起本视图是属主权限,不再是 invoker】,但这一段的结论
-- 未变:遮蔽视图的把关是 has_permission() 谓词,而 has_permission() 按 auth.uid()
-- 解析【调用者】,与谁拥有外层视图无关 —— 所以模块与数据类边界一字未动。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.

-- OPS-14(2026-08-08):改为【属主权限】+ 整表挂 module.finance.view。
-- 理由同 ap_open_items:存在判据"未结 > 0"本身就是财务计算,所以缺席的单位是整张视图。
-- customer 标签与产出批 code 跟着单据走。

-- ═══════════════════════════════════════════════════════════════════════════
-- 【SO-3a:第二支 —— 订单流发票】选项 C 之下开票即过账(借 1100 / 贷 2500),
-- 于是应收有了第二个来源:已过账、未结清的订单流发票。推导在
-- order_invoice_open_all(唯一一处 —— customer_ar_exposure_base 读的也是它,
-- 面板显示的余额与拒绝的那道闸必须是同一个数);本视图只加门与账龄。
-- doc_kind 判别两支('sale' / 'invoice'),消费方(收款核销、看板 ar_over_90、
-- 应收页)按它分支 —— ap_open_items 的 doc_kind 先例。账龄锚点:第二支从
-- issue_date 起算,与第一支从 sale_date 起算同构(都是"债生出来的那天")。
-- 【第二支要 data.view_prices,与第一支同效】第一支读 sales_records_masked,
-- 无 view_prices 时 unit_price 为 NULL → WHERE 求值为 NULL → 行整个消失;
-- 第二支读的是不遮蔽的内层视图,显式加同一道门,两支对同一读者同进同退。
--
-- 【SO-3b:两支不相交,由一条谓词兑现 —— 不再是一句承诺】
-- 发货产生的销售记录带着 sales_order_line_id 标记,第一支【显式排除】它们:
-- 那笔债在开票当刻就记过了,发货只是把负债释放进收入,不产生第二笔应收。
-- 少了这条谓词,同一笔钱会在账龄上出现两次 —— 一次以发票的身份、一次以
-- 销售记录的身份 —— 而两次都"看起来对"。这是选项 C 的核心不变量
-- (应收只创建一次)在这张视图上的落点,fixture 68 的 AR 静默臂钉住它。
--
-- 【SO-3a 那一段注释其实没有落地过,SO-3b 补写】原本要替换的锚点在标点上
-- 差一个字符(note. / note。),而那次用的是不带断言的 replace —— 于是它
-- 静默地什么都没做,视图体是对的、解释却一直缺席。与本仓库反复修的
-- "失败不是空集"同一个形状,只是长在工具脚本里。
-- ═══════════════════════════════════════════════════════════════════════════
CREATE VIEW public.ar_open_items WITH (security_invoker = off) AS
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
    AND sr.sales_order_line_id IS NULL
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
