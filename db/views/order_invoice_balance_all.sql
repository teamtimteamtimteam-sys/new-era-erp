-- db/views/order_invoice_balance_all.sql
-- CN-1:订单流发票的余额 ——【应收、敞口与贷项凭证天花板共同的那一处算术】。
--
-- NOTE: introduced by db/migrations/2026-08-15-cn1-credit-note.sql.
--
-- 【为什么劈成两张视图,而不是在 order_invoice_open_all 上改】
-- 那一张带着 open_ccy > 0 的过滤,因为它的两个消费方(账龄第二支、信用敞口
-- 第二项)问的都是"还欠着的有哪些"。而 create_credit_note 的天花板要问的是
-- 【这张发票现在还剩多少】—— 那个答案【可以是 0】,而 0 在一张过滤掉非正数的
-- 视图里表现为【没有行】。把"没有行"读成 0 正是这个仓库反复修的那条毛病
-- (mustRows / restRows / check-i18n 后缀解析:一次失败不是一个空集)。
-- 所以:算术只写这一遍,过滤留在外层那一张。三个消费方读到的是同一个数。
--
-- 【CN-1 加进来的那一项】open = Σ 明细行 − Σ 已结 − Σ 已贷记。
-- 收了钱是"结清",开了贷项凭证是"不再欠" —— 对"还剩多少"这个问题它们是同一个
-- 方向,所以在这里合并;但两者【分列】报出去,因为它们在客户那里是两件完全
-- 不同的事(付过 vs 不用付了),而账龄页那三个数必须仍然加得起来。
--
-- 【客户端读不到本视图】REVOKE SELECT —— 它不带 has_permission 的门,读得到它
-- 就等于绕过 module.finance.view 直接读全部客户的应收(与 order_invoice_open_all、
-- stock_class_violations_all 同一条)。三个消费方:两张属主权限视图(视图引用
-- 视图走属主替换)与一个 SECURITY DEFINER 函数,都够得着。
--
-- 【AP-RECON-1 Batch B(2026-09-24):一张订单发票欠的 = 净额 + 销项税,以发票币种计】
-- create_order_invoice 借 1100 两条腿(净额 round(Σ行 × 汇率) + 税 tax_base),而此前这里的
-- 金额只有 Σ 明细行 —— 于是一张带税的订单发票,清单、账龄、敞口、收款上限都只认净额,
-- 那笔税挂在 1100 上永远收不进来(fixture 213 C11:清单 1,200.00 / 总账 1,218.00)。
-- 与 Batch A 的费用单同一条(Tim AP-RECON-0 Q1 / AP-RECON-1 Batch B 追加裁定):
--   · amount_ccy = 净额 + 税(逐行 tax_amount_for,与 create_order_invoice 逐字同一个表达式);
--   · 已贷记 = 贷项凭证行的净额 + 它们各自的税(与 create_credit_note 同一个表达式);
--   · open_base = list_open_base —— 未结时就是过账那两条腿之和,结了一部分按 round(剩余×汇率)。
--     收款与贷项凭证的解除读的是同一个式子,于是 1100 为这张发票剩下的按构造等于这里。
--   · 末尾三列(net_ccy / tax_ccy / birth_base)给解除那一侧用;只追加,不动既有列序。
-- 不带税的发票:税 = 0、birth = round(净额 × 汇率),每一列逐字节不变。


CREATE VIEW public.order_invoice_balance_all WITH (security_invoker = off) AS
 SELECT i.id AS invoice_id,
    i.code,
    i.customer_id,
    i.issue_date,
    i.due_date,
    i.currency,
    i.fx_rate,
    round(l.net_ccy + l.tax_ccy, 2) AS amount_ccy,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_ccy,
    round(l.net_ccy + l.tax_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(cn.credited, 0::numeric), 2) AS open_ccy,
    list_open_base(round(l.net_ccy + l.tax_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(cn.credited, 0::numeric), 2), round(l.net_ccy + l.tax_ccy, 2), round(l.net_ccy * i.fx_rate, 2) + COALESCE(i.tax_base, 0::numeric), i.fx_rate) AS open_base,
    round(COALESCE(cn.credited, 0::numeric), 2) AS credited_ccy,
    round(COALESCE(cn.credited, 0::numeric) * i.fx_rate, 2) AS credited_base,
    l.net_ccy,
    l.tax_ccy,
    round(l.net_ccy * i.fx_rate, 2) + COALESCE(i.tax_base, 0::numeric) AS birth_base
   FROM invoices i
     JOIN LATERAL ( SELECT COALESCE(sum(il.amount_ccy), 0::numeric) AS net_ccy,
            COALESCE(sum(
                CASE
                    WHEN il.tax_code IS NULL THEN 0::numeric
                    ELSE tax_amount_for(il.amount_ccy, il.tax_rate_pct)
                END), 0::numeric) AS tax_ccy
           FROM invoice_lines il
          WHERE il.invoice_id = i.id) l ON true
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.invoice_id = i.id) s ON true
     LEFT JOIN LATERAL ( SELECT sum(cl.amount +
                CASE
                    WHEN cl.tax_code IS NULL THEN 0::numeric
                    ELSE tax_amount_for(cl.amount, cl.tax_rate_pct)
                END) AS credited
           FROM credit_note_lines cl
             JOIN credit_notes c ON c.id = cl.credit_note_id
          WHERE c.invoice_id = i.id) cn ON true
  WHERE i.kind = 'order'::text AND i.status = 'issued'::text;

COMMENT ON VIEW public.order_invoice_balance_all IS
    'CN-1:订单流发票的余额 ——【应收、敞口与贷项凭证天花板共同的那一处算术】,不带任何过滤。open_ccy = (Σ 明细行 + 销项税) − Σ 已结(posted 收款的核销)− Σ 已贷记(本发票的贷项凭证行,含税);open_base 走 list_open_base(未结时 = 过账的两条腿之和)。AP-RECON-1 Batch B 起含税。三个消费方:order_invoice_open_all(它就是本视图 WHERE open_ccy > 0,老的两个消费方因此一字未动)、create_credit_note 的天花板、invoice_status 的贷记列。【为什么不带过滤】天花板要问"现在还剩多少",而那个答案可以是 0 —— 在一张过滤掉非正数的视图里 0 表现为【没有行】,把"没有行"读成 0 正是本仓库反复修的那条毛病。【客户端读不到】:REVOKE SELECT —— 它不带 has_permission 的门。';

REVOKE SELECT ON public.order_invoice_balance_all FROM authenticated, anon;
