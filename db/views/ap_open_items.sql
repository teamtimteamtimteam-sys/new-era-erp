-- db/views/ap_open_items.sql
-- AP 开放余额(应付账龄):补充 2a 起是两类单据的 UNION,每张未结清单据一行。
--   * doc_kind 'inbound':已计价、在册的进料批次(规则不变);应付额 = 当前
--     quantity × unit_price(改价即改欠款);无到货日回退 created_at::date。
--   * doc_kind 'expense':挂账(unpaid)、posted 的开支单;应付额 = amount_base;
--     排除镜像行(被别的开支单指为 reversed_by_expense —— 它只是冲销的记录凭证,
--     不是新的应付单据),已冲销(reversed)的开支自然被 status 条件排除。
-- inbound_batch_id 列保留(expense 行为 NULL)—— 兼容按批次取行的旧调用方。
-- 结清额只计 status='posted' 付款单的核销行。【属主权限】—— 见 OPS-14 note。
--
-- cut 4a:进料侧的 settled_base 【还要加上 prepayment_applications】—— 定金冲抵的
-- 那部分钱同样在还这张批次的应付,不计进来的话,一张被定金付清的批次会永远显示未付。
-- 开支侧不受影响(预付只对采购订单成立)。列集未变,故本次是 CREATE OR REPLACE。
--
-- NOTE: prepayment applications folded in by
-- db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql; reworked by
-- db/migrations/2026-07-30-phase3-s2a-expenses.sql
-- (introduced by db/migrations/2026-07-06-phase3-cut3a-payments.sql).
-- 列集变了 → 重建时先 DROP VIEW 再 CREATE(CREATE OR REPLACE 改不了列)。

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的。【OPS-14 起本视图是属主权限,不再是 invoker】,但这一段的结论
-- 未变:遮蔽视图的把关是 has_permission() 谓词,而 has_permission() 按 auth.uid()
-- 解析【调用者】,与谁拥有外层视图无关 —— 所以模块与数据类边界一字未动。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.

-- OPS-14(2026-08-08):改为【属主权限】+ 整表挂 module.finance.view。
-- 借来的是【金额】:payment_allocations / payments 的核销额。原先 invoker 时
-- procurement(有 inbound + prices、无 finance)读 IN-2026-0029 得 已结 0 / 未结 48,000,
-- 真值是 已结 30,000 / 未结 18,000 —— 付了一大半的应付读起来一分没付。
-- 【为什么整表而不是把 settled/open 遮成 NULL】本视图的存在判据就是 `open_ccy > 0`,
-- 行在不在取决于一个财务计算;遮成 NULL 会把整张表过滤空,那不是"缺席"而是另一种谎。
-- 所以缺席的单位是【整张视图】:没有财务模块就 0 行,由一条明写的谓词给出。
-- supplier 标签跟着单据走。

-- FRT-1(2026-08-11):第三种单据 —— 未付运费单(对手方是【货代】)。
-- 少了这一支,那笔钱在总账里躺着、在账龄表上不存在。

-- PAYEE-1a(2026-08-18):费用支【由 INNER JOIN 改成 LEFT JOIN】,并新增
-- counterparty_kind / counterparty_id / counterparty_name 三列(追加在列尾,
-- 迁移里用 CREATE OR REPLACE(列追加在尾部),所以 operations_now 的依赖不必 DROP;
-- 本镜像是首次运行脚本,照惯例写 CREATE VIEW。
-- 【为什么必须改】原来是 JOIN suppliers —— 一条 supplier_id 为空的费用
-- 【整行消失】,不是显示成空白往来对象。那是 OPS-14 抓到的同一种病:
-- 静默丢行,没有错误,读者看到的是"这笔应付不存在"。
-- 【supplier_id / supplier_name 原样保留,员工行为 NULL】不把员工姓名塞进
-- 供应商那一列 —— 那正是 SUP-TYPE / PAYEE 这一系列在拆的那次混同。
-- 要"这笔欠谁"就读 counterparty_*,它们【永远非空】。
-- 【属主权限不变】employees 有 RLS(module.hr.view 或本人);本视图
-- security_invoker=off,所以财务读者不会因为没有 HR 权限而丢掉员工行
-- (OPS-14 的解法 a)。只借 legal_name 一个显示标签(AGENTS.md 第三条决定)。

-- AGING-1(2026-08-27):四条档位边界改为调用 aging_bucket() —— 全库唯一一处定义。
-- 【列集一字未动】,所以迁移走 CREATE OR REPLACE,operations_now 一类的依赖不必 DROP。
-- 【WITH (security_invoker = off) 是手写补回去的】pg_get_viewdef 不吐 reloptions
-- (PAYEE-1a 为此记过一次账),照它重建会把属主权限悄悄丢掉 —— 行为不变,
-- 但下一个读镜像的人会据此判断这张视图是不是刻意声明过。
--
-- 【本页不再读它了,而它留着】/finance/payables 改读 ap_aging_asof(as_of):
-- 一个 as-at 报表与一张"今天"的视图若各写一份档位边界,就是两份会漂开的实现。
-- 这张视图仍有别的消费方(看板 ap_over_90 等),所以留着;
-- db/fixtures/135 的 A 臂断言函数【截至今天】与它逐行逐列相同,两个方向差集都为空。

CREATE VIEW public.ap_open_items WITH (security_invoker = off) AS
 SELECT doc_kind,
    doc_id,
    doc_code,
    inbound_batch_id,
    supplier_id,
    supplier_name,
    doc_date,
    doc_value_base,
    settled_base,
    open_base,
    currency,
    open_ccy,
    CURRENT_DATE - doc_date AS days_outstanding,
    aging_bucket(CURRENT_DATE - doc_date) AS bucket,
    counterparty_kind,
    counterparty_id,
    counterparty_name
   FROM ( SELECT 'inbound'::text AS doc_kind,
            ib.id AS doc_id,
            ib.code AS doc_code,
            ib.id AS inbound_batch_id,
            ib.supplier_id,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
            round(ib.quantity * ib.unit_price, 2) AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric), 2) AS settled_base,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_base,
            ( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base) AS currency,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy,
            'supplier'::text AS counterparty_kind,
            ib.supplier_id AS counterparty_id,
            sup.legal_name AS counterparty_name
           FROM inbound_batches_masked ib
             JOIN suppliers sup ON sup.id = ib.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.inbound_batch_id = ib.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.inbound_batch_id = ib.id) pp ON true
          WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
        UNION ALL
         SELECT 'expense'::text AS doc_kind,
            e.id AS doc_id,
            e.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            e.supplier_id,
            sup.legal_name AS supplier_name,
            e.expense_date AS doc_date,
            e.amount_base AS doc_value_base,
            round((COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric)) * e.fx_rate, 2) AS settled_base,
            round((e.amount_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric)) * e.fx_rate, 2) AS open_base,
            e.currency,
            round(e.amount_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy,
                CASE
                    WHEN e.employee_id IS NOT NULL THEN 'employee'::text
                    ELSE 'supplier'::text
                END AS counterparty_kind,
            COALESCE(e.supplier_id, e.employee_id) AS counterparty_id,
            COALESCE(sup.legal_name, emp.legal_name) AS counterparty_name
           FROM expenses e
             LEFT JOIN suppliers sup ON sup.id = e.supplier_id
             LEFT JOIN employees emp ON emp.id = e.employee_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.expense_id = e.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_ccy) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.expense_id = e.id) pp ON true
          WHERE e.payment_status = 'unpaid'::text AND e.status = 'posted'::text AND NOT (EXISTS ( SELECT 1
                   FROM expenses o
                  WHERE o.reversed_by_expense = e.id))
        UNION ALL
         SELECT 'freight'::text AS doc_kind,
            fd.id AS doc_id,
            fd.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            fd.supplier_id,
            sup.legal_name AS supplier_name,
            fd.doc_date,
            fd.amount_base AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) * fd.fx_rate, 2) AS settled_base,
            round((fd.amount_ccy - COALESCE(s.settled, 0::numeric)) * fd.fx_rate, 2) AS open_base,
            fd.currency,
            round(fd.amount_ccy - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
            'supplier'::text AS counterparty_kind,
            fd.supplier_id AS counterparty_id,
            sup.legal_name AS counterparty_name
           FROM freight_documents fd
             JOIN suppliers sup ON sup.id = fd.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.freight_document_id = fd.id) s ON true
          WHERE fd.payment_status = 'unpaid'::text AND fd.status = 'posted'::text AND fd.deleted_at IS NULL) d
  WHERE open_ccy > 0::numeric AND has_permission('module.finance.view'::text);
