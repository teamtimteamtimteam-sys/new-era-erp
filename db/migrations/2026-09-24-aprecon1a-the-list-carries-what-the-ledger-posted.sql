-- AP-RECON-1 Batch A(2026-09-24):清单上欠的,就是总账上记的。
--
-- AP-RECON-0 把应付清单(ap_open_items)与总账 2000 之间 40,563.20 的差逐分钱拆开;
-- AP-RECON-1 的 grilling 把应收清单(ar_open_items)与 1100 之间 14,440.88 也拆开了。
-- 绝大部分是切换前的测试数据残留(记在 docs/known-wrong-until-cutover.md,不动)。
-- 剩下的是【活的缺陷】—— 每一条都会在今天的代码上继续把两边拉开。本迁移修其中四条
-- (Tim AP-RECON-1 Q1 = 分两批,这是 A 批):
--
--   1. 带税费用单的应付 = 净额 + 进项税(AP-RECON-0 Q1)。record_expense 贷 2000 两条腿,
--      清单、账龄、付款上限、预付冲抵上限、报销与医疗的"付清了没有"只认净额。
--      新增 expense_payable_ccy —— 与过账同一个表达式,一处定义。
--      附带:同一张单既要代扣又带税,按名拒(EXPENSE_WHT_WITH_GST;AP-RECON-1 Q2)。
--   2. 付款上限扣掉预付冲抵(AP-RECON-1 Q4)。record_payment_internal 的费用支漏了这一项:
--      EXP-2026-0006 清单上欠 280,000,付款路径却肯收 400,000。
--   3. sale 型发票的销项税是它自己的一项应收(AP-RECON-1 Q5)。create_invoice 借 1100 那笔税
--      (本位币),而清单与收款上限只认 数量×单价:INV-2026-0009 的 102.87 从来没有入口可收。
--      ar_open_items / ar_aging_asof 加第三支 'invoice_gst';收款可核销到 sale 型发票(只限它的税);
--      敞口、对账单跟着;作废 sale 型发票与 order 型同一条"有活核销不作废"。
--   4. 还欠着钱的已计价收货不许注销(AP-RECON-0 Q2):INBOUND_HAS_OPEN_PAYABLE。
--
-- 【第五条(日期)不在这里】AP-RECON-1 Q7 的三条日期规矩,按 Tim 2026-09-24 的裁定挪到
-- 它自己的一刀:32 份既有 fixture 刻意把过账记进 2027–2030,那一刀连同它们的改写一起做。
--
-- 【落地那一刻线上什么变】总账一分不动(0 张新分录);清单侧:
--   应付 +20.70(EXP-2026-0007 100→109、0008 30→32.70、0009 100→109),
--   应收 +102.87(INV-2026-0009 的税成为一行)。其余全是闸。
--
-- 每一个对象都从它的镜像原样取来(视图改成 CREATE OR REPLACE —— 列集一字未动)。

BEGIN;

-- ═══ db/functions/expense_payable_ccy.sql ═══
-- db/functions/expense_payable_ccy.sql
-- AP-RECON-1(2026-09-24):一张费用单【欠多少】,以单据币种计 = 净额 + 进项税。
--
-- 【为什么需要它】record_expense 挂账时贷 2000【两条腿】:净额 amount_ccy 与
-- 'GST on EXP-…' 那一条税。而未结清单、账龄、付款上限、预付冲抵上限、报销与医疗的
-- "付清了没有"此前全都只认 amount_ccy —— 于是一张带税的账单只能付到净额,那一笔税
-- 在 2000 上永远挂着、没有任何单据看得见它(AP-RECON-0 类别 C,线上 20.70)。
-- Tim AP-RECON-0 Q1:应付额 = 总账 2000 上为这张单记下的全部。
--
-- 【为什么可以精确地【算回来】,而不是存一列】record_expense 的税就是
-- tax_amount_for(p_amount, v_tax_rate),而 amount_ccy = p_amount、tax_rate_pct = v_tax_rate
-- 都原样落库。可抵与否只改借方科目,不改税额。于是这里与过账时是【同一个表达式】,
-- 不是第二份算术。tax_base / fx_rate 反推是有损的,所以不用它。
-- 未注册期与 GST 之前的行 tax_rate_pct 为 NULL → 税为 0 → 净额,与既有口径恒等。
--
-- NOTE: introduced by db/migrations/2026-09-24-aprecon1a-the-list-carries-what-the-ledger-posted.sql.
CREATE OR REPLACE FUNCTION public.expense_payable_ccy(p_amount_ccy numeric, p_tax_rate_pct numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT round(p_amount_ccy + COALESCE(tax_amount_for(p_amount_ccy, p_tax_rate_pct), 0), 2)
$function$;

-- ═══ db/views/ap_open_items.sql ═══
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

-- AP-RECON-1(2026-09-24):费用支的应付额 = 【净额 + 进项税】,即总账 2000 上为这张单
-- 记下的全部(record_expense 贷两条腿)。此前只认净额,一张带税的账单付到净额就从本视图
-- 消失,那一笔税在 2000 上永远挂着(AP-RECON-0 类别 C;Tim AP-RECON-0 Q1)。
--   · doc_value_base = amount_base + tax_base —— 过账时【存下来的】两个本位币数,逐分相同;
--   · open_ccy 用 expense_payable_ccy(与过账同一个表达式);
--   · open_base 在【一分未结】时直接取 doc_value_base:round((净+税)×汇率) 与
--     round(净×汇率)+round(税×汇率) 可以差一分,而未结的那一刻它必须与总账逐分相同。
-- 【列集一字未动】→ 迁移走 CREATE OR REPLACE。

CREATE OR REPLACE VIEW public.ap_open_items WITH (security_invoker = off) AS
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
            e.amount_base + COALESCE(e.tax_base, 0::numeric) AS doc_value_base,
            round((COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric)) * e.fx_rate, 2) AS settled_base,
                CASE
                    WHEN (COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric)) = 0::numeric THEN e.amount_base + COALESCE(e.tax_base, 0::numeric)
                    ELSE round((expense_payable_ccy(e.amount_ccy, e.tax_rate_pct) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric)) * e.fx_rate, 2)
                END AS open_base,
            e.currency,
            round(expense_payable_ccy(e.amount_ccy, e.tax_rate_pct) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy,
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

-- ═══ db/functions/ap_aging_asof.sql ═══
-- db/functions/ap_aging_asof.sql
-- AGING-1(2026-08-27):AP 账龄【截至某一天】。
--
-- 【为什么是函数不是视图】视图接不了参数,而 ap_open_items 把 CURRENT_DATE 焊在
-- 视图体里。但"截至"不止这一层 —— 完整的四层写在函数注释与
-- db/migrations/2026-08-27-aging1-as-at-a-date.sql 的抬头里:
--   ① 视图接不了参数 ② 结清额按付款日回推 ③ 单据在那天存在不存在 ④ 金额在那天是多少
--
-- 【p_as_of 默认今天,并且【等于今天时逐行复现 ap_open_items】】
-- db/fixtures/135 的 A 臂两个方向的差集都断言为空 —— 一次悄悄改变了当前数字的
-- 重构是这里能出的最坏结果,所以它由测量钉住,不由声明保证。
--
-- 【一处刻意的分歧】单据日期晚于 D 的单据本函数不收,而 ap_open_items 的进料支
-- 没有日期过滤、会收。fixture 135 的 H 臂把它变成一条被断言的行为。
--
-- NOTE: introduced by db/migrations/2026-08-27-aging1-as-at-a-date.sql.

CREATE OR REPLACE FUNCTION public.ap_aging_asof(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_as_of    date;
    v_today    date := CURRENT_DATE;
    v_start    date;
    v_base     text;
    v_rows     jsonb;
    v_buckets  jsonb;
    v_total    numeric;
    v_unpriced integer;
BEGIN
    -- 没有财务模块 → 【按名拒绝】,不是 0 行。两张老视图给的是 0 行
    -- (视图没有别的表达方式),而 0 行在页面上读作「没有未结单据」——
    -- 一句假话。函数有更好的表达方式,就该用。
    PERFORM require_permission('module.finance.view');

    -- 只读查询的"截至哪天",默认今天 —— 与 leave_balance / accrued_annual_leave
    -- 一族同一个惯用法,并已记在 docs/empty-string-to-rpc-audit.md 的白名单里。
    -- 【它不是那条"不许给日期默认值"的规矩的例外,是那条规矩的射程之外】:
    -- 那条管的是决定汇率、期间、金额的【写入】日期,而这里什么都不写。
    v_as_of := COALESCE(p_as_of, v_today);

    IF v_as_of > v_today THEN
        RAISE EXCEPTION 'AGING_AS_OF_FUTURE|%|%', v_as_of, v_today;
    END IF;

    SELECT fs.system_start_date INTO v_start FROM finance_settings fs LIMIT 1;
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.doc_date, x.doc_code), '[]'::jsonb)
      INTO v_rows
      FROM (
        -- ── 支一:已计价、在册的进料批次 ────────────────────────────────
        SELECT 'inbound'::text                                   AS doc_kind,
               ib.id                                             AS doc_id,
               ib.code                                           AS doc_code,
               ib.id                                             AS inbound_batch_id,
               ib.supplier_id                                    AS supplier_id,
               sup.legal_name                                    AS supplier_name,
               COALESCE(ib.arrival_date, ib.created_at::date)    AS doc_date,
               NULL::date                                        AS due_date,
               round(ib.quantity * pr.price, 2)                  AS doc_value_base,
               round(COALESCE(s.settled, 0) + COALESCE(pp.applied, 0), 2) AS settled_base,
               round(round(ib.quantity * pr.price, 2)
                     - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2) AS open_base,
               v_base                                            AS currency,
               round(round(ib.quantity * pr.price, 2)
                     - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2) AS open_ccy,
               (v_as_of - COALESCE(ib.arrival_date, ib.created_at::date))   AS days_outstanding,
               aging_bucket(v_as_of - COALESCE(ib.arrival_date, ib.created_at::date)) AS bucket,
               'supplier'::text                                  AS counterparty_kind,
               ib.supplier_id                                    AS counterparty_id,
               sup.legal_name                                    AS counterparty_name
          FROM inbound_batches_masked ib
          JOIN suppliers sup ON sup.id = ib.supplier_id
          -- 价格:D 那天的价,再套上与 inbound_batches_masked.unit_price
          -- 【逐字同源】的那道 data.view_prices 遮罩(见抬头)。
          CROSS JOIN LATERAL (
                SELECT CASE WHEN has_permission('data.view_prices')
                            THEN inbound_unit_price_asof(ib.id, v_as_of)
                       END AS price
          ) pr
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.inbound_batch_id = ib.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT sum(ppa.amount_base) AS applied
                  FROM prepayment_applications_masked ppa
                  LEFT JOIN journal_entries je ON je.id = ppa.journal_entry_id
                 WHERE ppa.inbound_batch_id = ib.id
                   AND COALESCE(je.entry_date, ppa.created_at::date) <= v_as_of
          ) pp ON true
         WHERE (ib.deleted_at IS NULL OR ib.deleted_at::date > v_as_of)
           AND COALESCE(ib.arrival_date, ib.created_at::date) <= v_as_of
           AND pr.price IS NOT NULL

        UNION ALL

        -- ── 支二:挂账开支 ─────────────────────────────────────────────
        SELECT 'expense'::text, e.id, e.code, NULL::uuid,
               e.supplier_id, sup.legal_name,
               e.expense_date, NULL::date,
               -- AP-RECON-1:净额 + 进项税,与 ap_open_items 费用支逐字同一套(见该视图抬头)。
               e.amount_base + COALESCE(e.tax_base, 0),
               round((COALESCE(s.settled, 0) + COALESCE(pp.applied, 0)) * e.fx_rate, 2),
               CASE WHEN (COALESCE(s.settled, 0) + COALESCE(pp.applied, 0)) = 0
                    THEN e.amount_base + COALESCE(e.tax_base, 0)
                    ELSE round((expense_payable_ccy(e.amount_ccy, e.tax_rate_pct) - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0)) * e.fx_rate, 2)
               END,
               e.currency,
               round(expense_payable_ccy(e.amount_ccy, e.tax_rate_pct) - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2),
               (v_as_of - e.expense_date),
               aging_bucket(v_as_of - e.expense_date),
               CASE WHEN e.employee_id IS NOT NULL THEN 'employee' ELSE 'supplier' END::text,
               COALESCE(e.supplier_id, e.employee_id),
               COALESCE(sup.legal_name, emp.legal_name)
          FROM expenses e
          LEFT JOIN suppliers sup ON sup.id = e.supplier_id
          LEFT JOIN employees emp ON emp.id = e.employee_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.expense_id = e.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT sum(ppa.amount_ccy) AS applied
                  FROM prepayment_applications_masked ppa
                  LEFT JOIN journal_entries je ON je.id = ppa.journal_entry_id
                 WHERE ppa.expense_id = e.id
                   AND COALESCE(je.entry_date, ppa.created_at::date) <= v_as_of
          ) pp ON true
         WHERE e.expense_date <= v_as_of
           -- 【为什么 payment_status 这个"现在"的标志还留着,而且必须留着】
           -- 实测:EXP-2026-0002 与 EXP-2026-0005 是 payment_status='paid' 却
           -- 【一条核销行都没有】—— 它们是当场付掉的,那笔钱根本不走 allocation。
           -- 所以"已付"在这套系统里【推导不出来】,只有那个标志说得出来。
           -- 于是判据写成:今天还挂着账 【或者】 它的结清发生在 D 【之后】。
           -- D = 今天时,后半永远为假(没有晚于今天的收付款 —— 实测 0 笔),
           -- 于是它逐字退化成今天那张视图的 `payment_status='unpaid'`。
           -- 这就是"默认今天等于今天的行为"在这一支上的落点。
           AND (e.payment_status = 'unpaid'
                OR EXISTS (SELECT 1 FROM payment_allocations pa2
                             JOIN payments p2 ON p2.id = pa2.payment_id
                            WHERE pa2.expense_id = e.id AND p2.payment_date > v_as_of)
                OR EXISTS (SELECT 1 FROM prepayment_applications ppa2
                             LEFT JOIN journal_entries je2 ON je2.id = ppa2.journal_entry_id
                            WHERE ppa2.expense_id = e.id
                              AND COALESCE(je2.entry_date, ppa2.created_at::date) > v_as_of))
           -- 单据在 D 那天【站着没有】:今天 posted 的站着;今天是 reversed 的,
           -- 若那次冲销发生在 D 之后,它在 D 那天也是站着的。
           AND (e.status = 'posted'
                OR (e.status = 'reversed'
                    AND (SELECT m.expense_date FROM expenses m
                          WHERE m.id = e.reversed_by_expense) > v_as_of))
           -- 镜像行照旧排除(它是冲销的记账凭证,不是一张新的应付单)
           AND NOT EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = e.id)

        UNION ALL

        -- ── 支三:未付运费单 ───────────────────────────────────────────
        SELECT 'freight'::text, fd.id, fd.code, NULL::uuid,
               fd.supplier_id, sup.legal_name,
               fd.doc_date, NULL::date,
               fd.amount_base,
               round(COALESCE(s.settled, 0) * fd.fx_rate, 2),
               round((fd.amount_ccy - COALESCE(s.settled, 0)) * fd.fx_rate, 2),
               fd.currency,
               round(fd.amount_ccy - COALESCE(s.settled, 0), 2),
               (v_as_of - fd.doc_date),
               aging_bucket(v_as_of - fd.doc_date),
               'supplier'::text, fd.supplier_id, sup.legal_name
          FROM freight_documents fd
          JOIN suppliers sup ON sup.id = fd.supplier_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.freight_document_id = fd.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
         WHERE fd.doc_date <= v_as_of
           AND (fd.deleted_at IS NULL OR fd.deleted_at::date > v_as_of)
           AND (fd.payment_status = 'unpaid'
                OR EXISTS (SELECT 1 FROM payment_allocations pa2
                             JOIN payments p2 ON p2.id = pa2.payment_id
                            WHERE pa2.freight_document_id = fd.id AND p2.payment_date > v_as_of))
           -- 运费单的冲销日:优先取【冲销分录的分录日】(那是业务日),
           -- 取不到才退回 reversed_at 的录入时刻。与 reverse_freight_document
           -- 用 CURRENT_DATE 立那张冲销分录逐字对应。
           AND (fd.status = 'posted'
                OR (fd.status = 'reversed'
                    AND COALESCE((SELECT je.entry_date FROM journal_entries je
                                   WHERE je.id = fd.reversal_entry_id),
                                 fd.reversed_at::date) > v_as_of))
      ) x
     WHERE x.open_ccy > 0;

    -- 档位合计:四档【一档不落】,没有的那一档是 0 而不是缺席 ——
    -- 一个缺席的键在页面上会渲染成空白,读起来像"没算出来"。
    SELECT jsonb_object_agg(b.bucket, COALESCE(agg.total, 0))
      INTO v_buckets
      FROM (VALUES ('b0_30'), ('b31_60'), ('b61_90'), ('b90_plus')) AS b(bucket)
      LEFT JOIN LATERAL (
            SELECT round(sum((e->>'open_base')::numeric), 2) AS total
              FROM jsonb_array_elements(v_rows) e
             WHERE e->>'bucket' = b.bucket
      ) agg ON true;

    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0)
      INTO v_total FROM jsonb_array_elements(v_rows) e;

    -- 【被"那天还没有价"挡掉的批次有几张】—— 一个缺席要说得出数目,
    -- 否则它与"本来就没有这笔应付"在屏幕上长得一模一样。
    -- 没有 data.view_prices 时这个数是 NULL 而不是 0:那不是"零张",
    -- 是"你看不到这一栏",与价格本身遮成 NULL 同一个道理。
    IF has_permission('data.view_prices') THEN
        SELECT count(*) INTO v_unpriced
          FROM inbound_batches ib
         WHERE (ib.deleted_at IS NULL OR ib.deleted_at::date > v_as_of)
           AND COALESCE(ib.arrival_date, ib.created_at::date) <= v_as_of
           AND inbound_unit_price_asof(ib.id, v_as_of) IS NULL;
    ELSE
        v_unpriced := NULL;
    END IF;

    RETURN jsonb_build_object(
        'side',                'ap',
        'as_of',               v_as_of,
        'today',               v_today,
        'is_past',             (v_as_of < v_today),
        'system_start_date',   v_start,
        'before_system_start', (v_start IS NOT NULL AND v_as_of < v_start),
        'base_currency',       v_base,
        -- 机器令牌,不是给人读的句子 —— 双语措辞留在 messages/,按语言选一条。
        'amount_basis',        'quantity_now_price_asof',
        'unpriced_excluded',   v_unpriced,
        'total_open_base',     v_total,
        'buckets',             v_buckets,
        'rows',                v_rows
    );
END;
$function$;

COMMENT ON FUNCTION public.ap_aging_asof(date) IS
    'AGING-1:AP 账龄【截至某一天】。视图接不了参数,而"截至"有四层而不是一层:① CURRENT_DATE 焊在视图体里;② 结清额要按付款日回推(晚于 D 的付款不算);③ 单据在 D 那天站着没有(D 之后的冲销/删除不回溯);④ 金额在 D 那天是多少(单价按 price_history 回推 —— 实测 2026-07-05 之前九张在开批次全部无价)。数量没有历史表,所以金额 = 今天的数量 × D 那天的价,由 amount_basis 明说。未来日期按名拒 AGING_AS_OF_FUTURE。截止日早于 system_start_date 不拒绝,返回 before_system_start 由页面与 CSV 各说一句(方向是把欠款报多)。p_as_of 默认今天,且【等于今天时逐行复现今天那张视图】—— db/fixtures/135 的 A 臂钉住。';

-- ═══ db/functions/apply_prepayment.sql ═══
CREATE OR REPLACE FUNCTION public.apply_prepayment(p_purchase_order_id uuid, p_inbound_batch_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text, p_expense_id uuid DEFAULT NULL::uuid, p_release_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user        uuid := auth.uid();
    v_base        text := base_currency_code();
    v_po          record;
    v_batch       record;
    v_exp         record;
    v_prepaid     numeric;   -- Σ 已付到该单的预付,本位币
    v_prepaid_ccy numeric;   -- Σ 同上,按【采购单币种】
    v_applied     numeric;   -- Σ 已冲抵,本位币
    v_available   numeric;
    v_dep_ccy     text;      -- 定金的币种 = 采购单的币种
    v_dep_rate    numeric;   -- 定金的加权平均汇率
    v_pay_ccy     text;      -- 被解除应付的计价币种
    v_pay_rate    numeric;   -- 被解除应付的【入账】汇率
    v_value       numeric;
    v_settled     numeric;
    v_open        numeric;
    v_dep_ccy_amt numeric;   -- 本次消耗的定金,按定金币种
    v_dep_base    numeric;   -- 本次消耗的定金,本位币(= 落库的 amount_base)
    v_pay_base    numeric;   -- 本次解除的应付,本位币
    v_realised    numeric;
    v_dest_code   text;      -- 目的地单据的编号(分录摘要用)
    v_lines       jsonb;
    v_app_id      uuid := gen_random_uuid();
    v_je          jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1c-b(X1):冲抵日【必填,永不默认】。
    -- 【它决定一个期间】这笔分录借 2000 / 贷 1300,过在哪一天就落在哪个月。
    -- 此前它是 CURRENT_DATE,而 AGENTS.md 那条规矩点名的正是这种默认:
    -- 今天的日期【永远撞不上 PERIOD_LOCKED】,于是"把日期留空"变成一条
    -- 比"填对一个已关期间的日期"更顺的路 —— 这条路奖励留空。
    -- 【为什么用"带默认值 + 按名拒",而不是让它位置上必填】FIN-10 那十一个函数
    -- 立的先例:老调用方少传一个参数时,应当拿到一句【人话】,而不是
    -- "function does not exist"。破窗期间生产跑的是旧代码,它就落在这一句上。
    IF p_release_date IS NULL THEN
        RAISE EXCEPTION 'RELEASE_DATE_REQUIRED';
    END IF;

    -- 目的地【恰好一个】。表上那条 CHECK 是兜底(直插也逃不掉);这里按名拒绝,
    -- 因为本仓库的规矩是"拒绝要有名字,屏幕上不出现裸的约束违例"。
    IF num_nonnulls(p_inbound_batch_id, p_expense_id) <> 1 THEN
        RAISE EXCEPTION 'PREPAY_DESTINATION_INVALID|%',
            num_nonnulls(p_inbound_batch_id, p_expense_id)
          USING HINT = '一次冲抵恰好冲一个目的地:一张进料批次,或一张费用单';
    END IF;

    SELECT po.id, po.code, po.supplier_id, po.status, po.approval_status, po.currency
    INTO v_po
    FROM purchase_orders po
    WHERE po.id = p_purchase_order_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;
    -- APR-2:未获批的采购单不能动钱
    IF v_po.approval_status <> 'approved' THEN
        RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_po.code, v_po.approval_status;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 定金那一侧。
    -- 【币种】1300 由 record_payment 按【单据(= 采购单)币种】归集(FIN-16 的
    -- v_pre 逐币种发行控制科目行),所以定金的币种就是采购单的币种。
    -- 【汇率】复用 FIN-16 已经记下来的结果,不重算:
    --     加权平均 = Σ allocated_base / Σ allocated_ccy
    -- ════════════════════════════════════════════════════════════════════════
    v_dep_ccy := v_po.currency;

    SELECT COALESCE(SUM(pa.allocated_base), 0), COALESCE(SUM(pa.allocated_ccy), 0)
    INTO v_prepaid, v_prepaid_ccy
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【可用预付这条守卫留在本位币空间 —— 这是刻意的,不要"顺手"改成币种空间】
    -- amount_ccy 在那一条 2026-07-31 的历史行上是 NULL(FIN-0 翻转之前记的,
    -- 刻意不回填)。一旦改成 Σ amount_ccy,那一行会被【静默跳过】,于是
    -- PO-2026-0001 上一笔【已经全额冲抵完】的 30,000 定金会读成"还有 30,000 可用",
    -- 冲第二次而没有任何东西反对。amount_base 在那一行上是有值的,所以本位币
    -- 空间数得对。币种是【记下来、过账用】的,不用来决定还剩多少。
    -- fixture 103b 的 H 臂把这一条钉死了。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT COALESCE(SUM(ppa.amount_base), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;

    v_available := round(v_prepaid - v_applied, 2);
    IF v_prepaid_ccy > 0 THEN
        v_dep_rate := v_prepaid / v_prepaid_ccy;
    END IF;
    IF v_dep_rate IS NULL OR v_dep_rate <= 0 THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', 0, p_amount;
    END IF;

    -- ── 目的地:两种单据,各自解出【计价币种】、【入账汇率】与【敞口】───────
    IF p_inbound_batch_id IS NOT NULL THEN
        SELECT ib.id, ib.code, ib.supplier_id, ib.quantity, ib.unit_price
        INTO v_batch
        FROM inbound_batches ib
        WHERE ib.id = p_inbound_batch_id AND ib.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
        END IF;
        IF v_batch.unit_price IS NULL THEN
            RAISE EXCEPTION 'INBOUND_UNPRICED|%', v_batch.code;
        END IF;
        IF v_batch.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_batch.code;
        END IF;

        -- 【进料应付恒以本位币计价】reprice_inbound_batch(set_inbound_unit_price
        -- 只是它的转发)按 base_currency_code() 过账 2000,ap_open_items 的进料支
        -- 也把 currency 取成 currencies.is_base。线上 9 条 source_type='purchase'
        -- 的 2000 行,fx_rate 无一例外是 1 —— 即当日的本位币。
        v_pay_ccy  := v_base;
        v_pay_rate := 1;

        v_value := round(v_batch.quantity * v_batch.unit_price, 2);
        SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_settled
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.inbound_batch_id = p_inbound_batch_id;
        v_settled := v_settled + COALESCE(
            (SELECT SUM(ppa.amount_base) FROM prepayment_applications ppa
              WHERE ppa.inbound_batch_id = p_inbound_batch_id), 0);
        v_open := round(v_value - v_settled, 2);
        v_dest_code := v_batch.code;
    ELSE
        SELECT e.id, e.code, e.currency, e.fx_rate, e.amount_ccy, e.tax_rate_pct,
               e.supplier_id, e.status, e.payment_status
        INTO v_exp
        FROM expenses e WHERE e.id = p_expense_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', COALESCE(p_expense_id::text, '?');
        END IF;
        IF v_exp.status <> 'posted' THEN
            RAISE EXCEPTION 'EXPENSE_NOT_POSTED|%|%', v_exp.code, v_exp.status;
        END IF;
        -- 已付的费用单没有应付可解除 —— 那笔钱当时就走了银行。
        IF v_exp.payment_status <> 'unpaid' THEN
            RAISE EXCEPTION 'EXPENSE_NOT_PAYABLE|%', v_exp.code
              USING HINT = '只有挂账(unpaid)的费用单才有应付可以让定金去冲';
        END IF;
        -- 冲销镜像单只是记录凭证,不是新的应付单据(ap_open_items 也把它排除)。
        IF EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = v_exp.id) THEN
            RAISE EXCEPTION 'EXPENSE_IS_REVERSAL_MIRROR|%', v_exp.code;
        END IF;
        IF v_exp.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_exp.code;
        END IF;

        -- 费用单的应付以【单据自己的币种】计价(record_expense 按 p_currency 贷 2000),
        -- 入账汇率就是单据上冻住的那一个。敞口因此在单据币种空间递减 ——
        -- 与 ap_open_items 的费用支同一个口径。
        v_pay_ccy  := v_exp.currency;
        v_pay_rate := v_exp.fx_rate;

        SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.expense_id = p_expense_id;
        v_settled := v_settled + COALESCE(
            (SELECT SUM(ppa.amount_ccy) FROM prepayment_applications ppa
              WHERE ppa.expense_id = p_expense_id), 0);
        -- AP-RECON-1:应付额是【净额 + 进项税】(expense_payable_ccy,与过账同一个表达式)——
        -- 只认净额的上限会让定金冲不掉那张单上的税,而那一笔税就挂在 2000 上没人能动。
        v_open := round(expense_payable_ccy(v_exp.amount_ccy, v_exp.tax_rate_pct) - v_settled, 2);
        v_dest_code := v_exp.code;
    END IF;

    -- p_amount 以【被解除应付的币种】陈述(进料支即本位币,与本刀之前逐字一致)
    IF p_amount > v_open THEN
        RAISE EXCEPTION 'EXCEEDS_OPEN|%|%', v_open, p_amount;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- R1 / R2 / R3 —— 判据是【定金币种】与【应付币种】的关系。
    -- 两条支路都【不读任何当日牌价】:两条腿都是历史入账,没有钱在动,
    -- 也就没有一次兑换需要定价。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_pay_ccy = v_dep_ccy THEN
        -- R1 单位对齐:付了 10,000 USD、欠 50,000 USD 的人,现在欠 40,000 USD。
        -- 已实现汇兑 = 同样这 A 个单位,按应付的入账汇率与按定金的加权汇率,
        -- 两个【历史】本位币值之差。
        v_dep_ccy_amt := p_amount;
        v_dep_base    := round(p_amount * v_dep_rate, 2);
        v_pay_base    := round(p_amount * v_pay_rate, 2);
    ELSIF v_pay_ccy = v_base OR v_dep_ccy = v_base THEN
        -- R2 价值对齐:两者恰有一个是本位币。按定金【自己的】汇率折出等值的
        -- 定金数量,于是两侧本位币值恒等,7100 恒为零。
        -- 【那个零是构造出来的,不是漏算的】1300 是 is_monetary = false:预付按
        -- 付款那天的汇率计量,此后永不重译。按它自己的汇率消耗它,不可能产生损益。
        v_pay_base    := round(p_amount * v_pay_rate, 2);
        v_dep_base    := v_pay_base;
        v_dep_ccy_amt := round(v_pay_base / v_dep_rate, 2);
    ELSE
        -- R3 两边都是外币且不同 —— 这才需要一次真正的换算,而这盘生意里它不存在。
        RAISE EXCEPTION 'PREPAY_TWO_FOREIGN_CURRENCIES|%|%', v_dep_ccy, v_pay_ccy
          USING HINT = '定金与应付是两种不同的外币 —— 请让其中一方以本位币开票';
    END IF;

    IF v_dep_ccy_amt IS NULL OR v_dep_ccy_amt <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF v_dep_base > v_available THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', v_available, v_dep_base;
    END IF;

    v_realised := round(v_pay_base - v_dep_base, 2);

    -- 分录:钱早就出去了,这里只是科目之间的搬运。
    -- 【汇率逐行给成 base/ccy 的商】与 record_payment 同一个手法 —— 这样
    -- post_journal_entry 折出来的本位币值与上面算的逐分相等,分录不会因为
    -- 一次四舍五入而不平,R2 的"恒为零"也才真的是零。
    v_lines := jsonb_build_array(
        jsonb_build_object('account_code', '2000', 'side', 'debit',
                           'currency', v_pay_ccy, 'amount_ccy', p_amount,
                           'fx_rate', v_pay_base / p_amount),
        jsonb_build_object('account_code', '1300', 'side', 'credit',
                           'currency', v_dep_ccy, 'amount_ccy', v_dep_ccy_amt,
                           'fx_rate', v_dep_base / v_dep_ccy_amt,
                           'line_memo', 'Prepayment applied'));
    -- 借方合计 − 贷方合计:>0 说明按旧率解除得多 → 贷 7100(益);<0 → 借 7100(损)。
    -- 与 record_payment 的方向约定逐字一致。
    IF v_realised > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
            'currency', v_base, 'amount_ccy', v_realised, 'fx_rate', 1);
    ELSIF v_realised < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
            'currency', v_base, 'amount_ccy', -v_realised, 'fx_rate', 1);
    END IF;

    v_je := post_journal_entry(
        p_release_date,
        -- 【不要写 COALESCE(v_batch.code, v_exp.code)】没走到的那一支里,那个
        -- record 变量【从未被赋值】,读它的字段是一个错误(record ... is not
        -- assigned yet),不是 NULL —— COALESCE 救不了。实测撞过。
        'Prepayment applied ' || v_po.code || ' → ' || v_dest_code,
        'prepayment', v_app_id, v_lines);

    INSERT INTO prepayment_applications (id, purchase_order_id, inbound_batch_id, expense_id,
                                         amount_base, currency, amount_ccy,
                                         notes, journal_entry_id, created_by)
    VALUES (v_app_id, p_purchase_order_id, p_inbound_batch_id, p_expense_id,
            v_dep_base, v_pay_ccy, p_amount,
            p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'application_id', v_app_id,
        'purchase_order_id', p_purchase_order_id,
        'inbound_batch_id', p_inbound_batch_id,
        'expense_id', p_expense_id,
        'currency', v_pay_ccy,
        'amount_ccy', p_amount,
        'amount_base', v_dep_base,
        'deposit_currency', v_dep_ccy,
        'deposit_amount_ccy', v_dep_ccy_amt,
        'deposit_rate', v_dep_rate,
        'realised_fx', v_realised,
        'journal_code', v_je->>'code',
        'prepaid_remaining', round(v_available - v_dep_base, 2)
    );
END;
$function$;

-- ═══ db/functions/record_payment_internal.sql ═══
-- db/functions/record_payment_internal.sql
-- PAY-REQ-1(2026-09-23):record_payment 的【函数体】搬到这里,一字不改,
-- 只拿掉了开头那一句 require_permission(见函数内的注释)。
--
-- 【为什么拆成内外两层,而不是给 record_payment 加一个参数】
-- Tim 的裁定:钱离开之前要先批(付款申请 → CFO 批准 → 付款)。于是出款要有三个
-- 调用方共用【同一份】算术:
--   ① record_payment —— 收款,以及豁免的出款(整笔付给员工、全部核销到已批准的
--      报销单 / 医疗申报生成的费用上;Tim 的 Q1);
--   ② pay_payment_request —— 付一张已批准的申请;
--   ③ payment_request_dry_run —— 提交与批准时按同一套规矩核一遍,再整个回滚。
-- 加一个"申请编号"参数会让 ① 也能被当成 ② 来调,于是要在函数里再比一遍冻结的
-- 参数 —— 那是第二份判据。拆开之后,付一张申请只有 ② 这一扇门(Q9:不加旁路参数)。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.record_payment_internal(p_direction text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_payment_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb, p_counterparty_kind text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind text;
    v_user         uuid := auth.uid();
    v_base         text;   -- OPS-8:本位币从 currencies.is_base 读
    v_date         date;
    v_fx           numeric;
    v_amount_base   numeric;
    v_doc_ccy      text;
    v_doc_fx       numeric;
    v_alloc_base   numeric;
    v_base_total   numeric := 0;
    v_bank_base    numeric;
    v_unalloc_ccy  numeric;
    v_unalloc_base numeric;
    v_po_pay_base  numeric;
    v_realised     numeric;
    v_po_base      numeric := 0;
    v_bank         text;
    v_payment_id   uuid := gen_random_uuid();
    v_code         text;
    v_alloc        jsonb;
    v_sale_id      uuid;
    v_batch_id     uuid;
    v_expense_id   uuid;
    v_po_id        uuid;
    v_invoice_id   uuid;   -- SO-3a:订单流发票(第六种核销去处)
    v_freight_id   uuid;   -- PAY-FRT:运费单(第七个字段、第六种【付款侧】去处)
    v_alloc_usd    numeric;
    v_doc_rate     numeric;   -- 单据币种在【结算日】的牌价(折算用,不是单据入账汇率)
    v_alloc_pay    numeric;   -- 本条核销消耗掉多少【付款币种】
    v_alloc_pay_total numeric := 0;  -- Σ 消耗的付款币种额(与 p_amount 同币种比较)
    -- 控制科目要按【单据币种】逐币种发行:一笔付款可以同时结掉 USD 单和 SGD 单,
    -- 那就是两条解除行,各自的原币与各自的入账汇率。键 = 单据币种。
    v_ctrl         jsonb := '{}'::jsonb;   -- 结算类(1100 / 2000)
    v_pre          jsonb := '{}'::jsonb;   -- 预付类(1300)
    v_ccy_key      text;
    v_grp          record;
    v_doc          record;
    v_doc_value    numeric;
    v_settled      numeric;
    v_open         numeric;
    v_alloc_total  numeric := 0;
    v_je           jsonb;
    -- 拆账与两遍处理用
    v_key          text;
    v_running      jsonb := '{}'::jsonb;   -- 目标 id → 本笔内已累计核销额
    v_prior        numeric;
    v_valid        jsonb := '[]'::jsonb;   -- ①校验通过的核销行,②之后据此落库
    v_po_usd       numeric := 0;           -- 本笔中指向 PO 的预付合计(USD)
    v_ap_usd       numeric;
    v_po_ccy       numeric;
    v_ap_ccy       numeric;
    v_cap          numeric;
    v_delta        numeric;
    v_found        boolean;
    v_lines        jsonb;
    -- ── WHT-1:代扣 ──────────────────────────────────────────────────────
    -- ★【这是本函数唯一一处"贷方 ≠ 付出去的钱"的地方,而那正是代扣的定义】★
    --   供应商的债按【全额】解除(借 2000 不变),银行只走【净额】,
    --   差额贷 2150 —— 一笔对 IRAS 的负债。三个数,一条分录。
    v_wht_rate       numeric;          -- 本条核销所属债务冻下来的税率(每轮重置)
    v_wht_ccy        numeric;          -- 本条要扣多少,单据币种
    v_wht_pay        numeric;          -- 同上,折成付款币种(现金算术用)
    v_wht_base       numeric;          -- 同上,折成本位币 —— 【落库与入账用的是同一个数】
    v_wht_pay_total  numeric := 0;     -- Σ,付款币种
    v_wht_base_total numeric := 0;     -- Σ,本位币 —— 要汇给 IRAS 的那个数
    v_payee_residence text;            -- 出款对手方申报的税务居民身份
    v_has_wht_obligation boolean;      -- 这个对手方名下有没有【要代扣的】在册债务
BEGIN
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    -- ★ PAY-REQ-1:这里【没有】权限检查 —— 这支是内层引擎,EXECUTE 已从
    --   authenticated 收回(db/views/zzz_function_grants.sql)。门在两个外壳上:
    --   record_payment(finance.edit,且出款要么豁免、要么拒绝)与
    --   pay_payment_request(finance.edit,且只付一张已批准的申请)。
    --   dry-run 也走这里(payment_request_dry_run),所以 CFO 批准时能核对同一套规矩
    --   —— 而 CFO 不持 finance.edit。
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    v_date := p_payment_date;
    -- 1. 基础校验
    IF p_direction IS NULL OR p_direction NOT IN ('in','out') THEN
        RAISE EXCEPTION 'DIRECTION_INVALID|%', COALESCE(p_direction, '?');
    END IF;

    -- PAYEE-1a:往来对象【是哪一种】不再由 direction 推断,而是说出来的。
    -- 不填时退回本刀之前的默认('in'→客户,'out'→供应商),于是既有调用方一字不改。
    -- 【为什么不靠"在供应商里找不到就去员工里找"】那是一次静默回退:
    -- 打错一个 uuid 会从"找不到"变成"在另一张表里也找不到",错误信息指向错的地方;
    -- 而一个真的两边都存在的 id(理论上可能)会挑中谁,没有人说得清。
    v_kind := COALESCE(NULLIF(btrim(p_counterparty_kind), ''),
                       CASE WHEN p_direction = 'in' THEN 'customer' ELSE 'supplier' END);

    IF p_direction = 'in' AND v_kind <> 'customer' THEN
        RAISE EXCEPTION 'COUNTERPARTY_KIND_INVALID|%|%', p_direction, v_kind;
    END IF;
    IF p_direction = 'out' AND v_kind NOT IN ('supplier', 'employee') THEN
        RAISE EXCEPTION 'COUNTERPARTY_KIND_INVALID|%|%', p_direction, v_kind;
    END IF;

    IF v_kind = 'customer' THEN
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM customers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    ELSIF v_kind = 'supplier' THEN
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM suppliers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
        -- WHT-1:出款对手方申报的税务居民身份。**只用来决定要不要【拦】** ——
        -- 实际扣多少一律读债务上冻下来的税率,不读这一列。一个已经记下的裁定
        -- 不能因为供应商今天改了身份就变一个数(见 expenses.wht_payee_residence)。
        SELECT tax_residence INTO v_payee_residence
        FROM suppliers WHERE id = p_counterparty_id;
    ELSE
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM employees WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0 三分支:
    --   本位币                     → 1,无换算;
    --   外币、且走该币种的外币户   → 没有发生兑换,按【付款日】牌价估值:
    --                                收款 tt_buy / 付款 tt_sell,当日无牌价即拒;
    --   外币、但走的不是该币种的户 → 银行【实际做了兑换】,必须递入按银行水单
    --                                实际金额折出的汇率(C4:实际兑换用实际数,
    --                                永远不用牌价);此时 p_fx_rate 必填。
    IF p_currency = v_base THEN
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
        END IF;
        v_fx := 1;
    ELSIF bank_native_currency(COALESCE(p_bank_account,
              bank_account_for_currency(p_currency))) = p_currency THEN
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
        END IF;
        v_fx := fx_rate_for(p_currency, v_date,
                            CASE WHEN p_direction = 'in' THEN 'tt_buy' ELSE 'tt_sell' END);
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    -- 银行科目:显式给了必须合法;不给按币种默认 —— 映射只有一份
    -- (bank_account_for_currency,bank_native_currency 的逆;同 lib/currencyMap.ts)
    IF p_bank_account IS NOT NULL THEN
        IF p_bank_account NOT IN ('1000','1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
        END IF;
        v_bank := p_bank_account;
    ELSE
        v_bank := bank_account_for_currency(p_currency);
    END IF;

    -- 2. USD 金额
    v_amount_base := round(p_amount * v_fx, 2);

    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN
        RAISE EXCEPTION 'ALLOC_INVALID|not_an_array';
    END IF;

    -- ========================================================================
    -- ① 核销行:逐条校验,不落库。顺序:存在 → 归属 → 计价 → 敞口。
    --    'in' 只认 sales_record_id / invoice_id;'out' 认 inbound_batch_id /
    --    expense_id / purchase_order_id(预付)/ freight_document_id(运费,PAY-FRT)。
    -- ========================================================================
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_sale_id    := (v_alloc->>'sales_record_id')::uuid;
        v_batch_id   := (v_alloc->>'inbound_batch_id')::uuid;
        v_expense_id := (v_alloc->>'expense_id')::uuid;
        v_po_id      := (v_alloc->>'purchase_order_id')::uuid;
        v_invoice_id := (v_alloc->>'invoice_id')::uuid;
        v_freight_id := (v_alloc->>'freight_document_id')::uuid;
        v_alloc_usd  := (v_alloc->>'amount_doc')::numeric;  -- FIN-2:单据币种金额
        -- 【每一轮重置】v_doc 是一个跨臂复用的 record,各臂 SELECT 出来的形状
        -- 并不相同 —— 所以代扣税率不能挂在 v_doc 上读,必须由本变量逐轮携带。
        -- 不重置的话,上一条要代扣的核销会把税率漏给下一条不该代扣的核销,
        -- 而那是一个算得出数、不报错的错误。
        v_wht_rate := NULL;

        IF v_alloc_usd IS NULL OR v_alloc_usd <= 0
           OR num_nonnulls(v_sale_id, v_batch_id, v_expense_id, v_po_id, v_invoice_id,
                           v_freight_id) <> 1 THEN
            RAISE EXCEPTION 'ALLOC_INVALID|%', v_alloc::text;
        END IF;

        IF p_direction = 'in' THEN
            IF v_batch_id IS NOT NULL OR v_expense_id IS NOT NULL OR v_po_id IS NOT NULL
               OR v_freight_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            IF v_invoice_id IS NOT NULL THEN
                -- ════════════════════════════════════════════════════════════
                -- SO-3a:订单流发票 —— 它自己就是应收单据(开票即 借1100/贷2500)。
                -- doc_value = Σ 明细行 amount_ccy(生成列,与 order_invoice_open_all
                -- 同口径);doc_fx = 发票【存下来的】入账汇率(从订单抄来的那一个)
                -- —— 结算按它解除,已实现汇兑(7100)也从它算起。开屏现查一个
                -- "今天的"汇率,会让同一张发票每天欠不一样的钱。
                -- 只认 kind='order' 且在册:sale 头的应收在 sales_records 上,
                -- 拿它的发票来核销就是同一笔债的第二个入口(ALLOC_INVALID)。
                -- ════════════════════════════════════════════════════════════
                -- ════════════════════════════════════════════════════════════
                -- AP-RECON-1(Tim AP-RECON-1 Q5):sale 型发票的【销项税】是它自己的
                -- 一项应收。create_invoice 在开票时借 1100 那一笔税(以本位币,即便
                -- 销售是 USD),而销售记录的上限只认 数量×单价 —— 那笔税此前没有任何
                -- 入口能收。所以 sale 型发票现在【只作为它那笔税】被核销:
                --   doc_value = invoices.tax_base(过账时存下的那个数),币种 = 本位币,
                --   汇率 = 1。净额仍然只在销售记录上收 —— 同一笔债不开第二个入口,
                --   上面那段话的原意不变,变的只是"税"这一笔此前根本没有入口。
                -- 不带税的 sale 型发票照旧 ALLOC_INVALID。
                -- ════════════════════════════════════════════════════════════
                SELECT i.id, i.code AS doc_code, i.customer_id AS party_id,
                       CASE WHEN i.kind = 'order'
                            THEN (SELECT COALESCE(sum(il.amount_ccy), 0) FROM invoice_lines il
                                   WHERE il.invoice_id = i.id)
                            ELSE i.tax_base END AS doc_value,
                       CASE WHEN i.kind = 'order' THEN i.currency ELSE v_base END AS doc_ccy,
                       CASE WHEN i.kind = 'order' THEN i.fx_rate ELSE 1::numeric END AS doc_fx
                INTO v_doc
                FROM invoices i
                WHERE i.id = v_invoice_id AND i.status = 'issued'
                  AND (i.kind = 'order' OR (i.kind = 'sale' AND i.tax_base > 0));
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'ALLOC_INVALID|%', v_invoice_id;
                END IF;
                IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                    RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
                END IF;
                v_doc_value := v_doc.doc_value;
                v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
                v_key := v_invoice_id::text;

                SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.invoice_id = v_invoice_id;
            ELSE
                SELECT sr.id, ob.code AS doc_code, sr.customer_id AS party_id,
                       round(sr.quantity * sr.unit_price, 2) AS doc_value,
                       sr.currency AS doc_ccy, sr.fx_rate AS doc_fx
                INTO v_doc
                FROM sales_records sr
                JOIN output_batches ob ON ob.id = sr.output_batch_id
                WHERE sr.id = v_sale_id;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'ALLOC_INVALID|%', v_sale_id;
                END IF;
                IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                    RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
                END IF;
                v_doc_value := v_doc.doc_value;
                v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
                v_key := v_sale_id::text;

                SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.sales_record_id = v_sale_id;
            END IF;

        ELSIF v_po_id IS NOT NULL THEN
            -- 预付款:PO 上【没有敞口上限】—— 定金不是在还债,那一刻还没有债。
            -- 唯一的栏杆是"累计预付不得超过估算总额 × 1.5",防手滑多打一个零。
            SELECT po.id, po.code AS doc_code, po.supplier_id AS party_id,
                   po.estimated_total_ccy, po.status AS po_status,
                   po.currency AS doc_ccy, po.fx_rate AS doc_fx,
                   po.approval_status AS po_approval
            INTO v_doc
            FROM purchase_orders po
            WHERE po.id = v_po_id AND po.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_po_id;
            END IF;
            IF v_doc.po_status = 'cancelled' THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_doc.doc_code;
            END IF;
            -- APR-2:未获批的采购单不能收预付款
            IF v_doc.po_approval <> 'approved' THEN
                RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_doc.doc_code, v_doc.po_approval;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            -- ★【WHT-1(A3):预付不在本刀范围内 —— 按名拒,不静默略过】★
            --   它在等的判断更硬:付给非居民顾问的一笔【定金】,本身就是一次
            --   代扣事件 —— 发生在任何发票存在【之前】,而这一刀的债务载体
            --   (expenses)那时还不存在。也就是说这不是"忘了接一根线",
            --   是本刀的裁定(代扣是债务的属性)在这条路上【还没有主语】。
            IF v_payee_residence = 'non_resident' THEN
                RAISE EXCEPTION 'WHT_PREPAYMENT_NOT_SUPPORTED|%', v_doc.doc_code
                  USING HINT = '付给非居民的定金本身就是一次代扣事件,而它发生在任何费用单之前 —— 本刀把代扣挂在债务上,预付那条路还没有债务可挂';
            END IF;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_key := v_po_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.purchase_order_id = v_po_id;

            -- 1.5 倍是【刻意留出的余量】:估算按谈价时的行情算,实际化验和金属价格
            -- 波动都会把真实金额顶高,预付超过估算是正常的;超过一半就不正常了。
            -- 【这条上限【不需要】折算 —— 两边本来就同币种,别再"顺手"加一次】
            -- v_alloc_usd 取自 amount_doc,按定义就是【单据币种】的金额;
            -- v_cap = estimated_total_ccy × 1.5,而 estimated_total_ccy 存的也是
            -- 【单据币种】(create_purchase_order 直接累加行金额,全程不乘汇率;
            -- 名字里的 _usd 是 FIN-1a 留下的旧名,与内容不符,见 docs/known-issues.md)。
            -- 两边同币种 ⇒ 付款是什么币种与这条上限【无关】,fixture 已断言:
            -- 同一张 PO、同一个 amount_doc,SGD 付款与 USD 付款结论完全一致。
            --
            -- 【FIN-16 曾经在这里写过一段相反的注释】,说这一支"需要单独折算"。
            -- 那是错的:代码从未折算,也不该折算,而那段注释举的例子(SGD 8,000 对
            -- USD 6,000 估算)两种算法都放行,根本区分不出有没有折算。
            -- 真正需要折算的是【付款额】那条守卫 ALLOC_EXCEEDS_PAYMENT ——
            -- 见下方 Σ 比较处;跨币种预付会不会超付,由它把关,不由这条上限把关。
            v_cap := round(v_doc.estimated_total_ccy * 1.5, 2);
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            IF round(v_settled + v_prior + v_alloc_usd, 2) > v_cap THEN
                RAISE EXCEPTION 'PREPAY_EXCEEDS_ESTIMATE|%|%|%',
                    v_doc.doc_code, round(v_settled + v_prior + v_alloc_usd, 2), v_cap;
            END IF;

            v_po_usd := round(v_po_usd + v_alloc_usd, 2);  -- FIN-2 起为单据币种累计
            v_doc_value := NULL;  -- 无敞口上限,跳过下面的 ALLOC_EXCEEDS

        ELSIF v_batch_id IS NOT NULL THEN
            IF v_sale_id IS NOT NULL OR v_invoice_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            SELECT ib.id, ib.code AS doc_code, ib.supplier_id AS party_id,
                   ib.unit_price, ib.quantity
            INTO v_doc
            FROM inbound_batches ib
            WHERE ib.id = v_batch_id AND ib.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_batch_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            IF v_doc.unit_price IS NULL THEN
                RAISE EXCEPTION 'ALLOC_UNPRICED|%', v_doc.doc_code;
            END IF;
            -- 应付额永远对着"当前"批次价值(改价即改欠款)
            v_doc_value := round(v_doc.quantity * v_doc.unit_price, 2);
            v_doc_ccy := v_base; v_doc_fx := 1;  -- FIN-0 起批次价值即本位币
            v_key := v_batch_id::text;

            -- 已结 = 收付款核销 + 预付冲抵(B6 起,预付冲抵也在还这张单的应付)
            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.inbound_batch_id = v_batch_id;
            v_settled := v_settled + COALESCE(
                (SELECT SUM(ppa.amount_base) FROM prepayment_applications ppa
                  WHERE ppa.inbound_batch_id = v_batch_id), 0);

        ELSIF v_freight_id IS NOT NULL THEN
            IF v_sale_id IS NOT NULL OR v_invoice_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            -- ════════════════════════════════════════════════════════════════
            -- PAY-FRT:未付运费单 —— 对手方是【货代】。
            -- 【这一臂逐字照着开支臂写,不是巧合,是判据】两者是同一种单据:
            -- 一张自带币种与入账汇率、贷 2000、挂在一个往来对象名下的应付。
            -- 于是敞口、跨币种结算、已实现汇兑三条全部落在下面【共用】的那段里,
            -- 本臂一行新的 FX 算术都没有 —— 新算术就是第二份算术。
            -- 【筛选条件与 ap_open_items 的运费支逐字一致】unpaid + posted +
            -- 未软删。少一条,画面上能选到的单据与这里能核销的单据就会分家,
            -- 而那正是本刀在关的那种缝。
            -- 【不存在 / 已付 / 已冲销 / 已软删 一律 ALLOC_INVALID】同开支臂:
            -- 四种情况在【调用方能做的事】上没有区别 —— 都是"这张单不能被核销"。
            -- ════════════════════════════════════════════════════════════════
            SELECT fd.id, fd.code AS doc_code, fd.supplier_id AS party_id,
                   fd.amount_ccy AS doc_value, fd.currency AS doc_ccy, fd.fx_rate AS doc_fx
            INTO v_doc
            FROM freight_documents fd
            WHERE fd.id = v_freight_id AND fd.payment_status = 'unpaid'
              AND fd.status = 'posted' AND fd.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_freight_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            -- ★【WHT-1(A3):运费不在本刀范围内 —— 按名拒,不静默略过】★
            --   它在等一个【没有人做过】的判断:付给非居民的运费,收款人如果是
            --   船公司/航空公司,是法定豁免的;如果是提供代理服务的货代,未必。
            --   两种情形在 freight_documents 上长得一模一样,而系统分不出来。
            --   静默放过 = 一笔本该代扣的款一分钱都没扣,且看起来完全正常。
            IF v_payee_residence = 'non_resident' THEN
                RAISE EXCEPTION 'WHT_FREIGHT_NOT_SUPPORTED|%', v_doc.doc_code
                  USING HINT = '付给非居民的运费是否代扣,取决于收款人是船公司/航空公司(豁免)还是提供代理服务的货代 —— 这个判断还没有人做过,本刀不猜';
            END IF;
            v_doc_value := v_doc.doc_value;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_key := v_freight_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.freight_document_id = v_freight_id;

        ELSE
            IF v_sale_id IS NOT NULL OR v_invoice_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            -- 挂账开支:必须是 unpaid + posted(不存在/已付/已冲销 → ALLOC_INVALID)
            -- PAYEE-1a:往来对象二选一,所以 party_id 取"那一个"。
            -- CHECK 保证 num_nonnulls(supplier_id, employee_id) = 1,于是 COALESCE
            -- 不会把两个混起来 —— 它挑的是唯一非空的那个。
            -- AP-RECON-1:应付额 = 净额 + 进项税(expense_payable_ccy,与过账同一个表达式;
            -- Tim AP-RECON-0 Q1)。只认净额时,一张带税账单的那笔税永远付不进来。
            SELECT e.id, e.code AS doc_code, COALESCE(e.supplier_id, e.employee_id) AS party_id,
                   expense_payable_ccy(e.amount_ccy, e.tax_rate_pct) AS doc_value,
                   e.currency AS doc_ccy, e.fx_rate AS doc_fx,
                   -- WHT-1:代扣率来自【债务自己冻下来的那一个】,不在这里重新解析。
                   -- 重新解析 = 第二份实现,而它会在法定税率某天变动之后,
                   -- 让一张旧债务按新税率被代扣 —— 算得出数,没有任何报错。
                   e.wht_rate_pct AS wht_rate_pct
            INTO v_doc
            FROM expenses e
            WHERE e.id = v_expense_id AND e.payment_status = 'unpaid' AND e.status = 'posted';
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_expense_id;
            END IF;
            v_wht_rate := v_doc.wht_rate_pct;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_doc_value := v_doc.doc_value;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_key := v_expense_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.expense_id = v_expense_id;
            -- AP-RECON-1(Tim AP-RECON-1 Q4):预付冲抵也在还这张单 —— ap_open_items 与
            -- apply_prepayment 早就这么算,只有这里漏了。漏掉时 EXP-2026-0006
            -- (400,000,已冲定金 120,000)在这里能再付 400,000,而清单上它只欠 280,000。
            -- 进料支(见上)一直是加上的;这里补成同一条。
            v_settled := v_settled + COALESCE(
                (SELECT SUM(ppa.amount_ccy) FROM prepayment_applications ppa
                  WHERE ppa.expense_id = v_expense_id), 0);
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【FIN-16】核销额是【单据的】金额,以单据币种计 —— 这一条来自 FIN-2,没变,
        -- 也正是它让单据恰好归零。变的是:付款【不必】是同一币种。
        -- 欠 USD 6,000 的客户拿 SGD 付清,这张单就是清了 —— 从前拒绝它不是安全护栏,
        -- 是缺了一个功能(旧 ALLOC_CURRENCY_MISMATCH 已删)。
        -- 本条核销消耗多少付款币种,由【结算日】两个币种的牌价折出来:
        --     消耗 = 单据额 × rate(单据币种) / rate(付款币种)
        -- 同币种时两率相同、比值为 1 —— 老路径逐字节不变,不需要特判。
        -- ════════════════════════════════════════════════════════════════════
        IF v_doc_ccy = p_currency THEN
            v_alloc_pay := v_alloc_usd;
        ELSE
            v_doc_rate := fx_rate_for(v_doc_ccy, v_date,
                            CASE WHEN p_direction = 'in' THEN 'tt_buy' ELSE 'tt_sell' END);
            v_alloc_pay := round(v_alloc_usd * v_doc_rate / v_fx, 2);
        END IF;
        v_alloc_pay_total := v_alloc_pay_total + v_alloc_pay;
        v_alloc_base := round(v_alloc_usd * v_doc_fx, 2);
        v_base_total := v_base_total + v_alloc_base;
        IF v_po_id IS NOT NULL THEN v_po_base := v_po_base + v_alloc_base; END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【WHT-1:代扣多少 —— 按【实际付掉的这一部分】算,不是按债务总额】
        -- 法定义务是"就你付出去的那部分代扣",所以部分结清只扣部分。
        -- 【为什么不按比例摊那张单冻下来的 wht_amount_ccy】按比例摊会在
        -- 多次部分付款之间累积取整误差,最后一次要靠"补齐余额"收口 ——
        -- 而那是一段谁都不敢改的算术。直接乘税率:每一次都精确,而且
        -- 全额付清时 Σ 恰好等于那张单冻下来的预期值(fixture 142 D 臂钉它)。
        IF v_wht_rate IS NOT NULL AND v_wht_rate > 0 THEN
            v_wht_ccy := round(v_alloc_usd * v_wht_rate / 100.0, 2);
            -- 折成付款币种走的是【与这条核销完全相同的那一步】,而不是另写一遍:
            -- 同币种取自身,跨币种用上面刚算出来的 v_doc_rate。
            IF v_doc_ccy = p_currency THEN
                v_wht_pay := v_wht_ccy;
            ELSE
                v_wht_pay := round(v_wht_ccy * v_doc_rate / v_fx, 2);
            END IF;
            v_wht_pay_total := v_wht_pay_total + v_wht_pay;
            -- 【本位币合计由【逐行的那个数】累加,不是最后对合计取一次整】
            -- 两种算法在同币种下相同,跨币种时可以差一分钱 —— 而那一分钱会落在
            -- 「2150 的贷方」与「payment_allocations 各行 withheld_base 之和」之间,
            -- 也就是【表头与它的明细对不上】。本仓库为这件事专门有一份 fixture
            -- (80「一个数字背后的那些行加起来等于那个数字」),所以这里按构造闭合:
            -- 落库的是这一个 v_wht_base,分录贷的是它们的和。
            v_wht_base := round(v_wht_pay * v_fx, 2);
            v_wht_base_total := v_wht_base_total + v_wht_base;
        ELSE
            v_wht_ccy := 0; v_wht_pay := 0; v_wht_base := 0;
        END IF;

        -- 敞口校验(预付除外:v_doc_value 为 NULL)。v_running 让同一目标在同一笔里
        -- 出现两次时,后一条能看见前一条 —— 原实现靠"边插边查"拿到的就是这个语义。
        IF v_doc_value IS NOT NULL THEN
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            v_open := round(v_doc_value - v_settled - v_prior, 2);
            IF v_alloc_usd > v_open THEN
                RAISE EXCEPTION 'ALLOC_EXCEEDS|%|%|%', v_doc.doc_code, v_alloc_usd, v_open;
            END IF;
        END IF;

        -- 按单据币种归集,供下面逐币种发行控制科目行
        v_ccy_key := v_doc_ccy;
        IF v_po_id IS NOT NULL THEN
            -- 预付是【非货币性】的,按付款日口径入账 —— 基准额取"消耗掉的付款额 ×
            -- 付款汇率",不是单据入账汇率(同币种时两者相等,老行为不变)。
            v_pre := v_pre || jsonb_build_object(v_ccy_key, jsonb_build_object(
                'ccy',  COALESCE((v_pre->v_ccy_key->>'ccy')::numeric, 0) + v_alloc_usd,
                'base', COALESCE((v_pre->v_ccy_key->>'base')::numeric, 0)
                        + round(v_alloc_pay * v_fx, 2)));
        ELSE
            v_ctrl := v_ctrl || jsonb_build_object(v_ccy_key, jsonb_build_object(
                'ccy',  COALESCE((v_ctrl->v_ccy_key->>'ccy')::numeric, 0) + v_alloc_usd,
                'base', COALESCE((v_ctrl->v_ccy_key->>'base')::numeric, 0) + v_alloc_base));
        END IF;

        v_running := v_running || jsonb_build_object(
            v_key, COALESCE((v_running->>v_key)::numeric, 0) + v_alloc_usd);
        v_valid := v_valid || jsonb_build_array(jsonb_build_object(
            'sales_record_id', v_sale_id, 'inbound_batch_id', v_batch_id,
            'expense_id', v_expense_id, 'purchase_order_id', v_po_id,
            'invoice_id', v_invoice_id, 'freight_document_id', v_freight_id,
            'amount_ccy', v_alloc_usd, 'amount_base', v_alloc_base,
            -- FIN-18:【消耗掉多少付款额】要落库。它是本函数唯一算得出、别处
            -- 再也算不回来的数 —— 见文件头。
            'amount_pay', v_alloc_pay,
            -- WHT-1:其中【没有付出去】的那一部分。allocated_pay 仍然是全额 ——
            -- 供应商的债确实按全额解除了,改它的含义会让 FIN-18 那段注释说谎。
            'withheld_pay', v_wht_pay,
            'withheld_base', v_wht_base));
        v_alloc_total := v_alloc_total + v_alloc_usd;
    END LOOP;

    -- Σ 核销不得超过款额(欠核销 = 挂账余额,允许)
    -- 【与页面同一个毛病的服务端孪生】v_alloc_total 是【单据币种】的合计,
    -- p_amount 是【付款币种】。同币种时看不出来;一旦不同,就是两种货币相减。
    -- 比较必须在付款币种空间做 —— 这正是两切次前在 /finance/payments 上修掉的
    -- 那个 bug,只是长在服务端。
    -- ════════════════════════════════════════════════════════════════════════
    -- ★【WHT-1:这一行【就是】代扣的结构位置,而它此前是不可能的】★
    --   本函数原来的不变量是 Σ核销 ≤ 付款额 —— 也就是【核销永远不能超过现金】。
    --   代扣要的恰恰是超过:结掉 10,000 的债,只付出去 8,500。
    --   于是比较的左边减去代扣额:**真正要与现金比的,是"要付出去的那部分"**。
    --   少了这一句,每一笔带代扣的付款都会撞上 ALLOC_EXCEEDS_PAYMENT,
    --   而错误信息会指向一个完全无辜的地方(看起来像超付)。
    IF round(v_alloc_pay_total - v_wht_pay_total, 2) > p_amount THEN
        RAISE EXCEPTION 'ALLOC_EXCEEDS_PAYMENT|%|%',
            round(v_alloc_pay_total - v_wht_pay_total, 2), p_amount;
    END IF;
    -- 【FIN-3 修订的 C2】已实现汇兑在【结算时点】认列:
    --   控制科目按【单据的】汇率解除(不变);银行按【结算日】口径(牌价/实际);
    --   差额进 7100(已实现)。只要单据汇率和当日汇率,两个数,不追每一块钱的均价。
    -- 未核销部分与预付(非货币,按付款日历史汇率入账)都按当日口径,不产生已实现差异。
    v_bank_base    := round(p_amount * v_fx, 2);
    v_amount_base  := v_bank_base;
    -- 未核销 = 款额 − 【已消耗的付款币种额】。原先减的是 v_alloc_total(单据币种合计)
    -- —— 同币种时相等,不同币种时就是两种货币相减,与 ALLOC_EXCEEDS_PAYMENT 同一个错。
    -- WHT-1:挂账 = 款额 − 【实际付掉的】那部分,而代扣的那部分从来没有付出去。
    -- 不减它,每一笔带代扣的付款都会凭空多出一笔等于代扣额的"挂账余额" ——
    -- 一笔并不存在的、对供应商的预付。
    v_unalloc_ccy  := round(p_amount - (v_alloc_pay_total - v_wht_pay_total), 2);
    v_unalloc_base := round(v_unalloc_ccy * v_fx, 2);
    -- 要汇给 IRAS 的那个数【已经在循环里逐行累加好了】。**按付款当日汇率折本位币**
    -- —— 代扣是今天新产生的一笔负债,不是在解除一笔旧的(与预付 1300 同一条口径);
    -- IRAS 只收新元。这里【不再对合计取一次整】,理由见循环里那段注释:
    -- 那会让 2150 的贷方与各行 withheld_base 之和差一分钱。

    -- ════════════════════════════════════════════════════════════════════════
    -- ★【WHT-1(A4):挂账付款给非居民 —— 【窄】的那一版拒绝】★
    --   一笔挂不上任何单据的出款,系统说不出它是什么性质,于是解析不出税率。
    --   GST 那一侧对【挂账收款】的处置是无条件按名拒
    --   (GST_UNALLOCATED_RECEIPT_UNSUPPORTED),而这里【故意不照抄】——
    --   理由必须写在这里,因为一次没有解释的、与兄弟规矩不同的做法,
    --   在下一个人读起来就是一处疏漏:
    --
    --   **那一条广,是因为在一笔挂账收款上,关于那项供应【什么都不可知】。
    --     这里不同:一个只卖过货的非居民,他的款一分钱都不该代扣 ——
    --     拦下它,是为了一个对他并不成立的理由而拦下一件正当的事。**
    --   而一条会在不适用的情形上开火的拒绝,会教会人绕开它 ——
    --   这个仓库为"学会忽略警报"付过账(hr_alerts.system_start_not_set)。
    --
    --   所以谓词收窄成:非居民 **且** 名下确实有过要代扣的债务。
    --   【残留的缺口,照直写】一个非居民,名下从来没有过要代扣的费用单,
    --   而这笔挂账付款正是给他的一项服务的预付 —— 它会通过。按名记在
    --   docs/known-issues.md,那是选窄版买来的代价,不是没想到。
    IF p_direction = 'out' AND v_unalloc_ccy > 0 AND v_payee_residence = 'non_resident' THEN
        SELECT EXISTS (
            SELECT 1 FROM expenses e
             WHERE e.supplier_id = p_counterparty_id
               AND e.status = 'posted'
               AND e.wht_nature IS NOT NULL
               AND e.wht_nature <> 'none'
        ) INTO v_has_wht_obligation;
        IF v_has_wht_obligation THEN
            RAISE EXCEPTION 'WHT_UNALLOCATED_PAYMENT_UNSUPPORTED|%|%', v_unalloc_ccy, p_currency
              USING HINT = '这个非居民收款人名下有要代扣的债务,而一笔挂账的款说不出它是什么性质、扣多少 —— 先记费用单,再核销到它上面';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【GST-2:"孰早"那条规矩的【另一半】,按名拦住而不是沉默地放过】
    -- 新加坡的供应时点是【开票与收款孰早】。GST-2 实现的是开票那一半;
    -- 收款那一半 —— 一笔【先于任何发票】收到的客户款 —— 同样触发供应,
    -- 而这套系统实现不了它:收款那一刻没有任何东西说得出这笔钱对应哪一项供应,
    -- 于是税码、税率、进哪一格三者都无从解析。
    -- **一条有两半的规矩,不许只做一半就当做完了。** 处置因此是按名拒绝:
    -- 已注册时,一笔挂不上任何单据的客户收款走不下去 —— 先开票,再收款核销。
    -- 【为什么不是"照收,记进 known-issues 就算了"】那样账上会留下一笔
    -- 【已经触发了供应却没有报税】的钱,而它看起来与一笔正常的挂账收款一模一样。
    -- 返回条件写在 docs/known-issues.md。
    IF p_direction = 'in' AND v_unalloc_ccy > 0 AND gst_registered() THEN
        RAISE EXCEPTION 'GST_UNALLOCATED_RECEIPT_UNSUPPORTED|%|%', v_unalloc_ccy, p_currency
          USING HINT = '已注册 GST 时,客户款必须核销到单据上:先开票,再收款';
    END IF;
    -- 预付部分占用的付款额(付款币种)→ 基准。原式 v_po_usd × v_fx 把单据币种的
    -- 数乘了付款汇率,跨币种时不成立;改为按各币种累加出来的基准额直接求和。
    SELECT COALESCE(SUM((value->>'base')::numeric), 0) INTO v_po_pay_base
    FROM jsonb_each(v_pre);
    -- 已实现 = 单据口径解除额 − 当日口径(同币种两率同为 1 ⇒ 恒为 0,不出现 FX 行)
    v_realised := round((v_base_total - v_po_base) - round((v_alloc_total - v_po_usd) * v_fx, 2), 2);

    -- ========================================================================
    -- ② 分录。'out' 且本笔含 PO 预付时【拆两条借方】:
    --      借 1300 预付款项  = 指向 PO 的部分
    --      借 2000 应付账款  = 其余(含未核销部分 —— 与改动前对全额借 2000 一致)
    --      贷 银行          = 全额
    --    金额:核销额是 USD,分录行按原币记,故 po_ccy = round(po_usd / fx, 2),
    --    ap_ccy = p_amount − po_ccy(【相减而非各自取整】,保证两条借方的原币恰好
    --    合计等于贷方)。USD 侧由 post_journal_entry 用 round(ccy × fx, 2) 反算,
    --    非本位币下双重取整可能差 1 分,故下面在 ±0.02 内挑一个能让 USD 恰好配平的
    --    拆分点(USD 付款 fx=1,偏移恒为 0)。
    -- ========================================================================
    v_code := fin_next_payment_code(CASE WHEN p_direction = 'in' THEN document_type_prefix('payment_receipt') ELSE document_type_prefix('payment_out') END, v_date);

    -- 行 fx = 目标基准额 ÷ 原币额(除后反乘取整恰好还原);0 金额行一律不发。
    v_lines := '[]'::jsonb;
    IF p_direction = 'in' THEN
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'debit',
            'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_bank_base / p_amount);
        -- 【逐单据币种】解除应收:金额是单据的原币,汇率是单据的入账汇率。
        -- 原先这里写死 p_currency —— 同币种时看不出来,两种币种时标签就是错的。
        FOR v_grp IN SELECT key AS ccy, (value->>'ccy')::numeric AS ccy_amt,
                            (value->>'base')::numeric AS base_amt
                     FROM jsonb_each(v_ctrl) ORDER BY key
        LOOP
            IF v_grp.ccy_amt > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '1100', 'side', 'credit',
                    'currency', v_grp.ccy, 'amount_ccy', v_grp.ccy_amt,
                    'fx_rate', v_grp.base_amt / v_grp.ccy_amt,
                    'line_memo', 'settled at document rate');
            END IF;
        END LOOP;
        IF v_unalloc_ccy > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '1100', 'side', 'credit',
                'currency', p_currency, 'amount_ccy', v_unalloc_ccy, 'fx_rate', v_unalloc_base / v_unalloc_ccy);
        END IF;
        -- 已实现差额:贷方合计 − 银行借方。>0 = 损(补借 7100),<0 = 益(补贷 7100)
        v_realised := round(COALESCE(v_base_total, 0) + v_unalloc_base - v_bank_base, 2);
        IF v_realised > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
                'currency', base_currency_code(), 'amount_ccy', v_realised);
        ELSIF v_realised < 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', -v_realised);
        END IF;
    ELSE
        FOR v_grp IN SELECT key AS ccy, (value->>'ccy')::numeric AS ccy_amt,
                            (value->>'base')::numeric AS base_amt
                     FROM jsonb_each(v_ctrl) ORDER BY key
        LOOP
            IF v_grp.ccy_amt > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '2000', 'side', 'debit',
                    'currency', v_grp.ccy, 'amount_ccy', v_grp.ccy_amt,
                    'fx_rate', v_grp.base_amt / v_grp.ccy_amt,
                    'line_memo', 'settled at document rate');
            END IF;
        END LOOP;
        IF v_unalloc_ccy > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '2000', 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_unalloc_ccy, 'fx_rate', v_unalloc_base / v_unalloc_ccy);
        END IF;
        FOR v_grp IN SELECT key AS ccy, (value->>'ccy')::numeric AS ccy_amt,
                            (value->>'base')::numeric AS base_amt
                     FROM jsonb_each(v_pre) ORDER BY key
        LOOP
            IF v_grp.ccy_amt > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '1300', 'side', 'debit',
                    'currency', v_grp.ccy, 'amount_ccy', v_grp.ccy_amt,
                    'fx_rate', v_grp.base_amt / v_grp.ccy_amt,
                    'line_memo', 'Prepayment');
            END IF;
        END LOOP;
        -- ════════════════════════════════════════════════════════════════════
        -- ★【WHT-1:代扣的那一笔 —— 债全额解除,钱只走净额】★
        --   借方(2000)已经是【全额】,银行贷方是【净额】(调用方递进来的
        --   p_amount 就是实际离开银行的钱),差额在这里贷 2150。
        --   **这就是 3.2 说的"代扣不是折扣"落成分录的样子**:供应商那张单
        --   闭合到零,而银行只动了净额,中间那一笔成为对 IRAS 的负债。
        --   【本位币记账,不带原币敞口】IRAS 只收新元,代扣额在付款那一刻
        --   就固定成一个新元数字 —— 它此后不再随汇率变动,所以这条腿走
        --   base_currency_code(),与 7100 那两条同一种写法。
        IF v_wht_base_total > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '2150', 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', v_wht_base_total,
                'line_memo', 'Withholding tax on ' || v_code);
        END IF;
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'credit',
            'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_bank_base / p_amount);
        -- 借方合计 − 银行贷方:>0 说明按旧率解除得多 → 贷 7100(益);<0 → 借 7100(损)
        -- 【减去代扣额】它是一条【新增的贷方】,不减就会被整个算进已实现汇兑,
        -- 把一笔代扣伪装成一笔汇兑损失 —— 而分录仍然是平的,不会有任何报错。
        v_realised := round((v_base_total - v_po_base) + v_unalloc_base + v_po_pay_base
                            - v_bank_base - v_wht_base_total, 2);
        IF v_realised > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', v_realised);
        ELSIF v_realised < 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
                'currency', base_currency_code(), 'amount_ccy', -v_realised);
        END IF;
    END IF;

    v_je := post_journal_entry(
        v_date,
        CASE WHEN p_direction = 'in' THEN 'Receipt ' ELSE 'Payment ' END || v_code,
        'payment', v_payment_id, v_lines);

    -- ③ 插入收付款单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          employee_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_payment_id, v_code, p_direction,
            v_kind,
            CASE WHEN v_kind = 'customer' THEN p_counterparty_id END,
            CASE WHEN v_kind = 'supplier' THEN p_counterparty_id END,
            CASE WHEN v_kind = 'employee' THEN p_counterparty_id END,
            p_amount, p_currency, v_fx, v_amount_base, v_bank,
            v_date, p_notes, (v_je->>'entry_id')::uuid, v_user);

    -- ④ 核销行落库(①已全部校验过,这里只写)
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(v_valid)
    LOOP
        INSERT INTO payment_allocations (payment_id, sales_record_id, inbound_batch_id,
                                         expense_id, purchase_order_id, invoice_id,
                                         freight_document_id,
                                         allocated_ccy, allocated_base, allocated_pay,
                                         withheld_pay, withheld_base)
        VALUES (v_payment_id,
                (v_alloc->>'sales_record_id')::uuid,
                (v_alloc->>'inbound_batch_id')::uuid,
                (v_alloc->>'expense_id')::uuid,
                (v_alloc->>'purchase_order_id')::uuid,
                (v_alloc->>'invoice_id')::uuid,
                (v_alloc->>'freight_document_id')::uuid,
                (v_alloc->>'amount_ccy')::numeric,
                (v_alloc->>'amount_base')::numeric,
                (v_alloc->>'amount_pay')::numeric,
                (v_alloc->>'withheld_pay')::numeric,
                (v_alloc->>'withheld_base')::numeric);
    END LOOP;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【FIN-18】返回值里原有 allocated_total = v_alloc_total 与
    -- unallocated = p_amount - v_alloc_total。函数体早已把分录与
    -- ALLOC_EXCEEDS_PAYMENT 都改到 v_alloc_pay_total(付款币种),【只有返回值
    -- 留在原地】:v_alloc_total 是各单据币种核销额的直接相加 —— 一张 USD 单
    -- 加一张 SGD 单;拿它去减付款币种的 p_amount 更是两种货币相减。
    -- 今天没有调用方读它(action 只取 payment_id),所以它不是 bug,是给下一个
    -- 调用方埋的坑。带单位的换上,没单位的撤掉。
    -- ════════════════════════════════════════════════════════════════════════
    RETURN jsonb_build_object(
        'payment_id', v_payment_id,
        'code', v_code,
        'currency', p_currency,                       -- 下面两个数的单位
        'amount_base', v_amount_base,
        'journal_code', v_je->>'code',
        'allocated_pay_total', round(v_alloc_pay_total, 2),  -- 付款币种:消耗掉的款额
        'unallocated', v_unalloc_ccy,                        -- 付款币种:挂账余额
        -- WHT-1:代扣了多少。**两个数分开报,而且各自带单位** ——
        -- withheld_pay 是现金算术里的那个数(付款币种),
        -- withheld_base 是【要汇给 IRAS 的那个数】(本位币)。
        -- 合成一个会重蹈 FIN-18 那个坑:一个没有单位的数,给下一个调用方埋雷。
        'withheld_pay_total', round(v_wht_pay_total, 2),
        'withheld_base_total', v_wht_base_total,
        -- 单据币种的核销额【按币种分开列】,不求和
        'settled_by_ccy', (SELECT COALESCE(jsonb_object_agg(key, value->'ccy'), '{}'::jsonb)
                             FROM jsonb_each(v_ctrl)),
        'prepaid_by_ccy', (SELECT COALESCE(jsonb_object_agg(key, value->'ccy'), '{}'::jsonb)
                             FROM jsonb_each(v_pre))
    );
END;
$function$
;

-- ═══ db/functions/record_expense.sql ═══
CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid, p_tax_code text DEFAULT NULL::text, p_wht_nature text DEFAULT NULL::text, p_wht_rate_pct numeric DEFAULT NULL::numeric, p_wht_treaty_ref text DEFAULT NULL::text, p_maintenance_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_account    record;
    v_fx         numeric;
    v_amount_base numeric;
    v_bank       text;
    v_expense_id uuid := gen_random_uuid();
    v_year       integer;
    v_seq        integer;
    v_code       text;
    v_je         jsonb;
    v_asset_id   uuid;
    v_append_id  uuid;   -- FA-1a:追加模式的目标资产
    v_target     fixed_assets%ROWTYPE;
    -- ── CAPEX-1 ──────────────────────────────────────────────────────────
    v_maint      equipment_maintenance%ROWTYPE;  -- 那条【说了这是资本化】的维修记录
    v_anchor_from date;    -- 新锚点从哪个月起
    v_prev       record;   -- 现行锚点(可能没有 —— 那就是首次资本化)
    v_pre_target numeric;  -- 锚点之前那一段的累计目标(存下来的常数)
    v_prev_start date;     -- 现行那一段是从哪天起算的
    v_prev_rem   numeric;  -- 现行那一段还剩几个月
    v_rem        numeric;  -- 新锚点剩几个月
    v_asset_code text;
    v_life       integer;
    v_residual   numeric;
    v_in_service date;
    v_poline     record;   -- EQP-1b-ii:这笔支出付的那一条采购单行
    v_poline_po  record;   -- 那一行所属的采购单
    v_billed     text;     -- 该行上已有的、【未冲销的】支出编号
    -- ── GST-2 ────────────────────────────────────────────────────────────
    v_tax_code   text;      -- 解析出来的进项税码(未注册时恒 NULL)
    v_tax_rate   numeric := 0;
    v_tax_ccy    numeric := 0;   -- 本单进项税,【单据币种】
    v_tax_base   numeric := 0;   -- 同上,本位币 —— 落库的那一个
    v_claimable  boolean := false;
    v_sup_default text;
    v_jlines     jsonb;
    v_cost_ccy   numeric;   -- 资本化口径:净额 + 【不可抵】的那笔税
    v_cost_base  numeric;
    -- ── WHT-1 ────────────────────────────────────────────────────────────
    v_residence     text;      -- 收款人【此刻】的税务居民身份,抄一份冻进这张单
    v_wht_nature    text;      -- 这笔款在预提税上是什么('none' = 显式的否)
    v_wht_rate      numeric;   -- 实际适用税率(条约减免后)
    v_wht_statutory numeric;   -- 当天的法定税率 —— 减免的上限
    v_wht_ccy       numeric := 0;  -- 全额结清时会代扣多少(单据币种,预期值)
    v_wht_ref       text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 科目:必须存在、启用,且是 expense 类型(只有 6xxx 是合法开支落点)
    IF p_expense_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;
    SELECT code, is_active, account_type INTO v_account
    FROM accounts WHERE code = p_account_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(p_account_code, '?');
    END IF;
    IF NOT v_account.is_active THEN
        RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code;
    END IF;
    -- FIN-22:资本性支出 —— 科目 1500 与 p_asset【互相要求】。
    --   * 1500 而无 p_asset:这条路上不许出现没有台账行的固定资产借方;
    --   * p_asset 而非 1500:资本标记只有一个落点,别的科目不接受;
    --   * 其余科目照旧只认 expense 类型("只有 6xxx 是合法开支落点"的原规矩)。
    IF p_account_code = '1500' THEN
        IF p_asset IS NULL THEN
            RAISE EXCEPTION 'CAPITAL_REQUIRES_ASSET|1500';
        END IF;
    ELSIF p_asset IS NOT NULL THEN
        RAISE EXCEPTION 'ASSET_REQUIRES_CAPITAL_ACCOUNT|%', v_account.code;
    ELSIF v_account.account_type <> 'expense' THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_EXPENSE|%', v_account.code;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1b-ii:这笔支出付的是【哪一条采购单行】。
    -- 整块只在 p_purchase_order_line 非空时生效 —— 绝大多数支出根本没有采购单
    -- (D1 那个可空就是为它们留的);而运保关税、安装、调试按 D5 挂在【资产】上
    -- 走追加模式,【不带】采购单行。列注释把这两句话写在了数据库里。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_purchase_order_line IS NOT NULL THEN
        SELECT l.id, l.line_no, l.asset_id, l.purchase_order_id
        INTO v_poline
        FROM purchase_order_lines l
        WHERE l.id = p_purchase_order_line;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', p_purchase_order_line;
        END IF;

        -- ── D2:与 apply_prepayment 同形的三条单据守卫 ────────────────────────
        -- 【"存在"= 没有被软删】apply_prepayment 的那句 WHERE 也带着 deleted_at,
        -- 照抄它是刻意的:少了这一句,一张已被软删的采购单照样收得下账单。
        SELECT po.id, po.code, po.supplier_id, po.status, po.approval_status
        INTO v_poline_po
        FROM purchase_orders po
        WHERE po.id = v_poline.purchase_order_id AND po.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PO_NOT_FOUND|%', v_poline.purchase_order_id;
        END IF;
        IF v_poline_po.status = 'cancelled' THEN
            RAISE EXCEPTION 'PO_CANCELLED|%', v_poline_po.code;
        END IF;
        IF v_poline_po.approval_status <> 'approved' THEN
            RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_poline_po.code, v_poline_po.approval_status;
        END IF;

        -- ── D3 上半:这条链接只在【设备行】上成立 ────────────────────────────
        -- 材料行经【收货】计价形成应付(reprice_inbound_batch),而收货量就是
        -- 它的计费上限。让费用单也挂得上去,等于给材料开【第二条计费路】,
        -- 而没有任何东西把这两条对得起来。同一条规矩也在表上(见下面那个触发器)。
        IF v_poline.asset_id IS NULL THEN
            RAISE EXCEPTION 'PO_LINE_NOT_EQUIPMENT|%', v_poline.line_no
              USING HINT = '材料行经收货计价形成应付,不经费用单';
        END IF;

        -- ── D3 下半:支出的资产必须【就是】行上那一台 ────────────────────────
        -- 拆成三种情形分别点名,因为它们的【修法互不相同】。合成一句"资产对不上"
        -- 会把两种根本不是"对不上"的情形也说成对不上 —— 尤其是新建那一支:
        -- 那里的资产是这一刻才生出来的,报一个"你填的 id 与行上的不符"
        -- 会打发人去核对一个一毫秒之前还不存在的 id。
        IF p_asset IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_NOT_CAPITAL|%|%', v_poline.line_no, p_account_code
              USING HINT = '挂在设备行上的支出必须是资本支出:科目 1500 + p_asset';
        END IF;
        IF (p_asset->>'asset_id') IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_CREATES_ASSET|%', v_poline.line_no
              USING HINT = '设备行引用的资产卡【已经存在】(行不创建资产),这笔支出要以追加模式挂上去:p_asset.asset_id';
        END IF;
        IF (p_asset->>'asset_id')::uuid <> v_poline.asset_id THEN
            RAISE EXCEPTION 'EXPENSE_ASSET_MISMATCH|%|%', p_asset->>'asset_id', v_poline.asset_id
              USING HINT = 'B 机器的发票不能记到 A 机器的订单行上';
        END IF;

        -- ── D2 第四条:供应商一致 —— 但先问【有没有供应商】────────────────────
        -- 【这条规矩的主体可以缺席】expenses_counterparty_shape 只对 unpaid 强制
        -- 往来对象;paid 的费用单 supplier_id 合法地为空(线上那 2 笔就是)。
        -- 于是"供应商一致"若直接写成比较,对一半的单据是拿 NULL 去比 ——
        -- 那不是"不一致",是"没人说过"。两件事两个名字。
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_SUPPLIER_NOT_STATED|%', v_poline_po.code
              USING HINT = '挂在采购单行上的支出必须说出开这张票的供应商';
        END IF;
        IF p_supplier_id <> v_poline_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_poline_po.code, p_supplier_id;
        END IF;

        -- ── D4:覆盖推导 —— 一条设备行只报销一次 ─────────────────────────────
        -- 【必须排除已冲销的】一笔冲销掉的支出【没有发生过】,它的行因此重新
        -- 可计费。判据只有一句:status = 'posted'。它站得住,是因为
        -- guard_expense_mutation 只放行 posted→reversed 且同时首挂
        -- reversed_by_expense,并且拒绝一切 DELETE —— 两列永远同步,
        -- 所以 status='reversed' 与 reversed_by_expense IS NOT NULL 是同一件事。
        -- 【这段话原本说"冲销了再记一笔"会把成本记成 170,000 —— EQP-1b-iii 之后
        --   它不再成立,所以就地退休,而不是留在这里骗下一个读它的人。】
        -- 当时(EQP-1b-ii)的实测是:冲销一笔追加模式的资本支出【允许】、分录冲掉、
        -- 而 cost_base 与成本明细原样不动,于是"冲销再记"= 100,000 的机器记成 170,000。
        -- EQP-1b-iii 修好了那一条:冲销现在会把成本退回去,并当场核对
        -- 表头 = 未冲销明细之和。所以【未投用】的机器,"冲销那笔支出再记一笔"
        -- 现在是一条安全的路,消息里也就照直说了。
        -- 【但它只在未投用时安全】资产一旦投用,冲销按名拒
        -- (ASSET_IN_SERVICE_COST_LOCKED),而向下修正一台已投用资产的成本
        -- 今天【没有任何路】—— 记在 docs/known-issues.md,带返回条件。
        -- 消息因此仍然把【改订单】放在前面:发票与估价对不上时,那才是要改的东西。
        -- 【第二层是索引】uq_expenses_live_po_line,谓词与这里逐字相同。
        -- 这里负责【可读】(带上占着这条行的那张单的编号),索引负责【正确】
        -- (并发下两笔同时通过本判据时,只有一笔落得下去)—— invoice_lines 的原话。
        SELECT e.code INTO v_billed
        FROM expenses e
        WHERE e.purchase_order_line_id = p_purchase_order_line
          AND e.status = 'posted'
        LIMIT 1;
        IF v_billed IS NOT NULL THEN
            RAISE EXCEPTION 'PO_LINE_ALREADY_EXPENSED|%|%', v_poline.line_no, v_billed
              USING HINT = '一条设备行只报销一次。若是【订单上的估价】与发票对不上,要改的是订单(改行,不是删行),不是再记一笔';
        END IF;
    END IF;

    -- 2. 金额/币种/汇率(FIN-0:SGD 本位免换算,外币按费用日牌价估值)
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【费用日】的行方卖出价(tt_sell)估值 ——
    -- 应付与开销是我们将来要【向银行买】的外币。当日无牌价即拒(FX_RATE_MISSING)。
    -- 汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, p_expense_date, 'tt_sell');

    -- 3. 支付状态
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;
    -- ★★ PAY-REQ-1(Tim 的 Q2(c),2026-09-23):一张费用单【不许生下来就是已付】。
    --   'paid' 这条路直接贷银行、不经 payments、不经 SOD、不经任何批准 ——
    --   是"钱离开之前要先批"那条规矩旁边的一扇侧门。从此费用一律挂账(unpaid),
    --   钱经付款申请 → CFO 批准 → 付款离开。默认值也从 'paid' 改成了 'unpaid'
    --   (一个走默认值就撞拒绝的参数,是 WHT-1 记过的那种坑)。
    --   已批准的流程生成的费用(报销单、医疗申报)本来就传 'unpaid',不受影响;
    --   加工费付款(relieve_processing_accruals)直接写 expenses、不经本函数,也不受影响。
    --   下面 'paid' 那一支因此到不了,留着是为了让这一刀只改一句判断。
    IF p_payment_status = 'paid' THEN
        RAISE EXCEPTION 'EXPENSE_PAID_AT_CREATION_REFUSED'
          USING HINT = '费用先挂账(未付),再提付款申请、经 CFO 批准后付款(PAY-REQ-1)';
    END IF;

    IF p_payment_status = 'paid' THEN
        -- paid:银行科目显式给了必须合法;不给按币种默认 —— 映射只有一份
        -- (bank_account_for_currency,bank_native_currency 的逆)
        IF p_bank_account IS NOT NULL THEN
            IF p_bank_account NOT IN ('1000','1010') THEN
                RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
            END IF;
            v_bank := p_bank_account;
        ELSE
            v_bank := bank_account_for_currency(p_currency);
        END IF;
    ELSE
        -- unpaid:必须有在册供应商(它要成为 AP 单据);银行科目必须为空 ——
        -- 传了也直接忽略(挂账时根本没动银行,存下来只会误导)
        -- PAYEE-1a:往来对象【二选一】—— 供应商 或 员工,恰好一个。
        -- 【两个都给是矛盾,不是"取其一"】一笔钱不可能同时欠着两个人;
        -- 悄悄挑一个会让另一个人的账凭空消失,所以按名拒绝。
        IF num_nonnulls(p_supplier_id, p_employee_id) = 0 THEN
            RAISE EXCEPTION 'COUNTERPARTY_REQUIRED_FOR_UNPAID';
        END IF;
        IF num_nonnulls(p_supplier_id, p_employee_id) > 1 THEN
            RAISE EXCEPTION 'COUNTERPARTY_AMBIGUOUS';
        END IF;
        IF p_supplier_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
        END IF;
        IF p_employee_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM employees WHERE id = p_employee_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_employee_id;
        END IF;
        v_bank := NULL;
    END IF;

    -- 4. USD 金额。**p_amount 始终是【不含税净额】** —— 供应商账单上的总额
    --    是净额 + 税,而这一列记的是开支本身的价值。GST 关着时两者相等,
    --    所以这条口径对既有行为是恒等的。
    v_amount_base := round(p_amount * v_fx, 2);

    -- ════════════════════════════════════════════════════════════════════════
    -- 4b. GST-2:进项税码 —— 【供应商默认 + 本单改写】,税率按【费用日】解析。
    -- 【为什么费用日就是税点】进项侧的税点是供应商那张税务发票的日期,
    -- 而 record_expense 的 p_expense_date 记的正是那一天。总账口径与法定口径
    -- 在进项侧本来就重合 —— 所以 F5 的进项侧仍然从总账推导,那不是妥协。
    -- ════════════════════════════════════════════════════════════════════════
    IF gst_registered() THEN
        SELECT default_tax_code INTO v_sup_default FROM suppliers WHERE id = p_supplier_id;
        -- 【没有供应商的 paid 单据必须自己带码】那是合法的一种单据
        -- (线上就有两笔),而它没有可以继承默认的对象 —— 于是要么本单指定,
        -- 要么按名拒。不猜。
        v_tax_code := resolve_tax_code(p_tax_code, v_sup_default, 'input', 'supplier');
        v_tax_rate := tax_rate_for(v_tax_code, p_expense_date);
        -- PO-GST-1:提取成 tax_amount_for —— 【表达式一个字符都没变】,
        -- 只是这一行此前在三处各写了一遍。见该函数抬头。
        v_tax_ccy  := tax_amount_for(p_amount, v_tax_rate);
        v_tax_base := round(v_tax_ccy * v_fx, 2);
        SELECT is_claimable INTO v_claimable FROM tax_codes WHERE code = v_tax_code;
    ELSE
        -- 【未注册:与建 GST 之前一模一样】传了码要按名拒,不能悄悄忽略。
        IF NULLIF(btrim(COALESCE(p_tax_code, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'GST_NOT_REGISTERED|%', p_tax_code;
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 4c. WHT-1:预提税 —— **这张单要不要替收款人代扣,以及扣多少**。
    --
    -- ★【这【不是】GST 的第二个实例,两者在这张单上做的是相反的事】★
    --   进项税是【加】在供应商账单上、公司还能要回来的钱;
    --   预提税是【从】要付给供应商的钱里【扣下来】、替他交给 IRAS 的钱。
    --   所以这一段不碰分录:记这张费用单的时候什么都没扣 —— 债是全额的。
    --   代扣发生在【付款】那一刻(record_payment),因为法定义务是就
    --   "你实际付出去的那部分"代扣。这里只把【裁定】冻下来。
    --
    -- 【裁定的三个部件,以及它们各自的来路】
    --   ① 居民身份 —— 从 suppliers.tax_residence 抄一份冻住(见列注释);
    --   ② 性质     —— 由记账人显式回答,'none' 是一个合法且显式的"否";
    --   ③ 税率     —— wht_rate_for(性质, 费用日),条约减免时由本单覆盖并出示凭据。
    -- ════════════════════════════════════════════════════════════════════════
    v_residence  := NULL;
    v_wht_nature := NULLIF(btrim(COALESCE(p_wht_nature, '')), '');
    v_wht_ref    := NULLIF(btrim(COALESCE(p_wht_treaty_ref, '')), '');
    IF p_supplier_id IS NOT NULL THEN
        SELECT tax_residence INTO v_residence FROM suppliers WHERE id = p_supplier_id;
    END IF;

    IF v_wht_nature IS NOT NULL THEN
        -- ── 有人断言这张单要做代扣裁定 ──────────────────────────────────
        -- 【收款人必须是供应商】员工与"只有名字的收款人"都到不了这里:
        -- employees 没有税务居民身份这一列,而 payee_name 是一段自由文本 ——
        -- 对一段文本做税务裁定是没有主语的。两者都是【具名缺席】,记在
        -- docs/known-issues.md,不是靠这里悄悄放过。
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'WHT_PAYEE_NOT_A_SUPPLIER|%', v_wht_nature
              USING HINT = '预提税裁定只能落在一个在册供应商上 —— 员工报销与只有名字的收款人不在本刀范围内';
        END IF;
        IF v_residence IS NULL THEN
            RAISE EXCEPTION 'WHT_RESIDENCE_NOT_STATED|%', p_supplier_id
              USING HINT = '这家供应商还没有申报税务居民身份 —— 先在供应商档案上填,再记这张单';
        END IF;
        IF v_residence <> 'non_resident' THEN
            -- 居民收款人不代扣。悄悄扣 0 会在账上留下一条"想过了"的假痕迹。
            RAISE EXCEPTION 'WHT_PAYEE_IS_RESIDENT|%|%', p_supplier_id, v_wht_nature
              USING HINT = '这家供应商申报的是新加坡税务居民 —— 付给他的款不代扣';
        END IF;
        -- ★【A2:'paid' 那一支按名拒,并且【说出该怎么走】】★
        --   record_expense 的 p_payment_status 默认就是 'paid',而那一支
        --   借 6xxx / 贷银行 一步到位,不产生应付、不经过 record_payment ——
        --   也就是不经过唯一知道怎么劈账的那段代码。让它自己也会劈,
        --   就是把同一份算术写第二遍(AGENTS.md 的预览规则,已犯四次)。
        --   【一条不指路的拒绝,在默认路径上就是一条会被绕开的拒绝】——
        --   所以 HINT 说的是走法,不是"不行"。
        --   ★【判据是【真的要扣钱吗】,不是【回答了这个问题吗】★
        --   fu2 修正:原实现把这道拒绝放在解析税率【之前】,谓词只看
        --   "有没有给性质"。于是对一个非居民收款人当场付清一笔【不适用代扣】的
        --   款(性质 = 'none',税率 0),它也拒 —— 而那一支非居民收款人的
        --   paid 费用单因此【一条路都没有】:不回答被 WHT_NATURE_REQUIRED 拒,
        --   回答"不适用"被这一条拒。**一个两边都堵死的问题,不是一道闸,是一堵墙。**
        --   所以税率先解析,再按【税率 > 0】判 —— 没有钱要被扣下来的时候,
        --   paid 那一支没有任何东西需要劈,也就没有理由拦它。
        --   (界面那一侧本来就写对了:`whtNature !== 'none' && paid` 才提示。
        --    两边不一致时先问哪一边错了 —— 这一次错的是服务端。)
        v_wht_statutory := wht_rate_for(v_wht_nature, p_expense_date);
        IF p_wht_rate_pct IS NULL THEN
            -- 没有主张条约减免:按法定税率。
            IF v_wht_ref IS NOT NULL THEN
                RAISE EXCEPTION 'WHT_TREATY_REF_WITHOUT_RATE|%', v_wht_ref
                  USING HINT = '给了居民证明书编号却没有给协定税率 —— 两者要么都给,要么都不给';
            END IF;
            v_wht_rate := v_wht_statutory;
        ELSE
            IF p_wht_rate_pct < 0 THEN
                RAISE EXCEPTION 'WHT_TREATY_RATE_INVALID|%', p_wht_rate_pct;
            END IF;
            -- 【永远不许高于法定】协定只会调低,不会调高。高于法定的"减免"
            -- 是一个打错的数字,而它会算得出来。
            IF p_wht_rate_pct > v_wht_statutory THEN
                RAISE EXCEPTION 'WHT_TREATY_RATE_ABOVE_STATUTORY|%|%|%',
                    v_wht_nature, p_wht_rate_pct, v_wht_statutory;
            END IF;
            -- 【低于法定必须出示凭据】没有居民证明书,IRAS 按法定税率征,
            -- 协定写什么都不作数 —— 所以少扣的那一部分是公司自己要补的钱。
            IF p_wht_rate_pct < v_wht_statutory AND v_wht_ref IS NULL THEN
                RAISE EXCEPTION 'WHT_TREATY_REF_REQUIRED|%|%|%',
                    v_wht_nature, p_wht_rate_pct, v_wht_statutory
                  USING HINT = '低于法定税率要凭居民证明书(Certificate of Residence)—— 填它的编号';
            END IF;
            v_wht_rate := p_wht_rate_pct;
        END IF;
        -- ★【A2:'paid' 那一支按名拒,并且【说出该怎么走】】★
        --   record_expense 的 p_payment_status 默认就是 'paid',而那一支
        --   借 6xxx / 贷银行 一步到位,不产生应付、不经过 record_payment ——
        --   也就是不经过唯一知道怎么劈账的那段代码。让它自己也会劈,
        --   就是把同一份算术写第二遍(AGENTS.md 的预览规则,已犯四次)。
        --   【一条不指路的拒绝,在默认路径上就是一条会被绕开的拒绝】——
        --   所以 HINT 说的是走法,不是"不行"。
        --   【谓词是税率 > 0】见上面 fu2 那段:不扣钱就没有要劈的东西。
        IF p_payment_status = 'paid' AND v_wht_rate > 0 THEN
            RAISE EXCEPTION 'WHT_ON_PAID_EXPENSE_UNSUPPORTED|%', v_wht_nature
              USING HINT = '要代扣的费用请先记成【未付】(挂应付),再用付款功能付掉 —— 代扣在付款那一步发生,那里只有一份劈账的实现';
        END IF;

        -- 【预期值:全额结清时会扣多少】真正的代扣按实付部分算,见 record_payment。
        v_wht_ccy := round(p_amount * v_wht_rate / 100.0, 2);
    ELSE
        -- ── 没有给性质 ──────────────────────────────────────────────────
        IF p_wht_rate_pct IS NOT NULL OR v_wht_ref IS NOT NULL THEN
            RAISE EXCEPTION 'WHT_NATURE_REQUIRED|rate_without_nature'
              USING HINT = '给了协定税率或证明书编号,却没有说这笔款是什么性质';
        END IF;
        -- ★【承重的那一条】★ 收款人【申报过】是非居民,就必须回答这个问题。
        --   答"不适用"用 'none' —— 它是一个显式的否,不是一个空白。
        --   身份为 NULL 时【不问】:那是一个量过成本的取舍,理由整段写在
        --   db/tables/suppliers.sql 的 tax_residence 列注释里,不在这里复述。
        IF v_residence = 'non_resident' THEN
            RAISE EXCEPTION 'WHT_NATURE_REQUIRED|%', p_supplier_id
              USING HINT = '收款人是非居民 —— 说明这笔款的预提税性质;确实不适用就选「不适用代扣」(none),不要留空';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1(Tim AP-RECON-1 Q2):【同一张单既要代扣又带进项税 —— 按名拒】
    --   应付额现在是 净额 + 税(expense_payable_ccy),而代扣按【实付的核销额】× 税率算
    --   (record_payment)。两者同在一张单上,代扣就会把 GST 也扣进去,Σ 代扣超过这里冻下的
    --   wht_amount_ccy(fixture 142 D 臂钉的那个等式)。
    --   而这个组合在现实里本不该出现:要代扣的是【非居民】收款人,非居民供应商不收新加坡 GST
    --   (进口服务走反向征收,不是账单上的税)。线上 0 张这样的单。所以拒绝不挡任何真业务,
    --   只挡一个会让两条规矩算出互相矛盾的数的输入。判据与 A2 同形:【真的要扣钱】且【真的有税】。
    -- ════════════════════════════════════════════════════════════════════════
    IF COALESCE(v_wht_rate, 0) > 0 AND COALESCE(v_tax_ccy, 0) > 0 THEN
        RAISE EXCEPTION 'EXPENSE_WHT_WITH_GST|%|%', v_wht_nature, v_tax_code
          USING HINT = '要代扣预提税的非居民收款人不应在账单上收新加坡 GST —— 请核对税码(非居民服务通常不带进项税码)';
    END IF;

    -- 【资本化口径:不可抵的进项税【是】资产成本的一部分】
    -- 可抵的税要得回来,它从来不是成本;不可抵的税(BL —— 私家车是最典型的
    -- 那一类)要不回来,于是它和买价一样是为了取得这台资产付出去的钱。
    -- 【为什么不在这里按名拒掉 BL + 资本】那会把一个【有确定答案的】会计问题
    -- 说成一个待裁决的问题。ASSET_ALREADY_IN_SERVICE 那条拒绝之所以成立,
    -- 是因为"投用后的追加是资本化改良还是当期费用"真的需要人来判;这一条不需要。
    v_cost_ccy  := round(p_amount    + CASE WHEN v_claimable THEN 0 ELSE v_tax_ccy  END, 2);
    v_cost_base := round(v_amount_base + CASE WHEN v_claimable THEN 0 ELSE v_tax_base END, 2);

    -- 5. 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款编号手法);失败回滚会释放号码。
    v_year := EXTRACT(YEAR FROM p_expense_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE document_type_prefix('expense') || '-' || v_year::text || '-%';
    v_code := document_type_prefix('expense') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 6. 先过分录(source_id = 预生成的 expense id,无需回填),期间锁在此生效。
    --    paid → 贷银行;unpaid → 贷 2000 应付。行走原币。
    -- ── GST-2:分录的形状 ────────────────────────────────────────────────
    -- 【净额那条腿带税码】F5 的 box5 = Σ(借−贷) FILTER (tax_code IN (TX,ZP,BL)),
    -- 所以它报的是【采购净额】,这正是 IRAS 要的"应税采购总额"。
    v_jlines := jsonb_build_array(
        jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                           'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx,
                           'tax_code', v_tax_code));
    IF v_tax_ccy > 0 THEN
        IF v_claimable THEN
            -- 可抵:税借 1400 进项税 —— box7 就是从这个科目推导的。
            v_jlines := v_jlines || jsonb_build_object('account_code', '1400', 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_tax_ccy, 'fx_rate', v_fx,
                'line_memo', 'input tax ' || v_tax_code);
        ELSE
            -- 【不可抵(BL)不是"没有税",是"有税但要不回来"】那笔税进【开支本身】。
            -- 【这条腿【不带】税码】带上它,box5 报的就成了含税额,而 IRAS 要的是
            -- 采购价值 —— 税码存在的全部理由正是"税率分不开可抵与不可抵"。
            v_jlines := v_jlines || jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_tax_ccy, 'fx_rate', v_fx,
                'line_memo', 'blocked input tax ' || v_tax_code);
        END IF;
    END IF;
    -- 【贷方拆成两条腿,而不是一条总额腿】供应商收的是净额 + 税,但
    -- post_journal_entry 是【逐行】round(原币 × 汇率) 的:一条 round((净+税)×fx)
    -- 的腿与两条 round(净×fx) + round(税×fx) 的借方腿会差一分钱,而那一分钱
    -- 会撞上提交时的借贷平衡触发器。两条腿按构造精确对冲,不靠运气。
    v_jlines := v_jlines || jsonb_build_object(
        'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
        'side', 'credit',
        'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx);
    IF v_tax_ccy > 0 THEN
        v_jlines := v_jlines || jsonb_build_object(
            'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
            'side', 'credit',
            'currency', p_currency, 'amount_ccy', v_tax_ccy, 'fx_rate', v_fx,
            'line_memo', 'GST on ' || v_code);
    END IF;

    v_je := post_journal_entry(
        p_expense_date,
        'Expense ' || v_code || ' ' || p_account_code,
        'expense', v_expense_id,
        v_jlines
    );

    -- 7. 插入开支单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id, employee_id,
                          payee_name, notes, journal_entry_id, created_by,
                          purchase_order_line_id,
                          tax_code, tax_rate_pct, tax_base,
                          -- WHT-1:裁定冻在债务上。居民身份是【抄下来的一份】,
                          -- 不是一个指向 suppliers 的引用 —— 供应商日后迁走管理与
                          -- 控制、身份跟着变,不能倒过来改写一张已经记下的债务。
                          wht_payee_residence, wht_nature, wht_rate_pct,
                          wht_amount_ccy, wht_treaty_ref)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, p_amount, p_currency, v_fx,
            v_amount_base, p_payment_status, v_bank, p_supplier_id, p_employee_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user,
            p_purchase_order_line,
            v_tax_code,
            CASE WHEN v_tax_code IS NULL THEN NULL ELSE v_tax_rate END,
            v_tax_base,
            -- 【只有做过裁定的单据才带身份】没有裁定时这四列全空,与
            -- expenses_wht_shape 那条 CHECK 的第一支逐字对应。居民收款人、
            -- 员工报销、身份未申报 —— 三种情况在这里都是空,而它们的
            -- 【区别】记在别处(拒绝的名字、以及 /finance/wht 数出来的缺口)。
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_residence END,
            v_wht_nature,
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_rate END,
            CASE WHEN v_wht_nature IS NULL THEN 0    ELSE v_wht_ccy END,
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_ref END);

    -- FIN-22:资本行 → 同一事务生成台账。成本 = 本单金额;汇率 = 上面按
    -- 【费用日 = 购置日】取的 tt_sell 牌价 —— 资产是非货币项目,这个汇率
    -- 定格成本,永不重译(表注有言,重估扫不到 1500/1510)。
    IF p_asset IS NOT NULL THEN
        -- ── FA-1a:同一扇门,两种模式 ────────────────────────────────────────
        -- 【为什么不开第二个函数】1500 ↔ p_asset 的互相要求是这条路上唯一的
        -- 不变量:没有台账行的 1500 借方进不来,资本标记也落不到别的科目上。
        -- 再开一个 add_cost_to_asset() 等于开第二扇门,而那个不变量只守得住
        -- 第一扇 —— 与"单据不该有第二个写法"同一条(so_issues / approval_log)。
        -- 所以追加走【同一个函数】:p_asset 带 asset_id 就是追加,不带就是新建。
        v_append_id := (p_asset->>'asset_id')::uuid;

        IF v_append_id IS NOT NULL THEN
            -- ── 追加成本(运费、关税、安装调试)──────────────────────────
            SELECT * INTO v_target FROM fixed_assets WHERE id = v_append_id FOR UPDATE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ASSET_NOT_FOUND|%', v_append_id;
            END IF;
            IF v_target.status <> 'active' THEN
                RAISE EXCEPTION 'ASSET_DISPOSED|%', v_target.code;
            END IF;

            -- ════════════════════════════════════════════════════════════════
            -- ★★【CAPEX-1:投用之后的追加 —— 那条【一律拒】换成了一条【窄】的】★★
            --
            -- FIN-22 原本在这里无条件拒(ASSET_ALREADY_IN_SERVICE),而它守的是
            -- **两件事**,必须分开说,因为只有一件被解决了:
            --   ① 【算术危险】抬高 cost_base 会让累计目标算法把过去每一个月
            --      重算一遍,整笔补提落在本期。
            --      —— 这一件由 fixed_asset_depreciation_anchors 【结构性】解决了:
            --      锚点之前那一段成了一个存下来的常数,新成本乘不到它身上。
            --   ② 【会计判断】投用后的花费算资本化改良,还是算当期费用?
            --      —— 这一件【没有】被解决,也解决不了:它是人的判断。
            --
            -- 所以窄的那条规矩保住的正是②:**判断仍然交还给人,只是人现在可以
            -- 在系统里回答,而不是被挡在门外。** 而回答的地方【不新开一处】——
            -- equipment_maintenance 已经是记录这个判断的地方(capitalised +
            -- capitalisation_reason,表上有 CHECK 逼理由非空),而
            -- capitalised_expense_id 这一列的注释早就写着它在等的就是这一刀。
            --
            -- 【为什么不接受一段自由文本的理由参数】那会让"这笔钱是资本化的、
            -- 理由是什么"同时住在两张表里,而两处之间没有任何链接 ——
            -- 一个判断两个真源。Tim 2026-08-29 裁定:走维修记录这一条路。
            --
            -- 【那条被关掉的路,按名拒并说出走法】一次不经维修记录的中途升级
            -- (比如按采购而不是按维修记下来的)今天没有路。**不给它开第二个
            -- 入口**:两个来源加一条优先级规则,是第二个定义披着"打平局"的外衣。
            -- 拒绝要指路 —— 先记一条维修记录、标资本化并写明理由,再对着它资本化。
            IF v_target.in_service_date IS NOT NULL THEN
                IF p_maintenance_id IS NULL THEN
                    RAISE EXCEPTION 'ASSET_IN_SERVICE_NEEDS_MAINTENANCE|%|%',
                        v_target.code, v_target.in_service_date
                      USING HINT = '给一台在跑的机器追加成本,要先有一条【标了资本化并写明理由】的维修记录,再对着它资本化 —— 那个判断(资本化改良 vs 当期费用)是人的,系统不替你做';
                END IF;
                SELECT * INTO v_maint FROM equipment_maintenance
                 WHERE id = p_maintenance_id FOR UPDATE;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'MAINTENANCE_NOT_FOUND|%', p_maintenance_id;
                END IF;
                -- 【维修记录必须指着【这一台】】否则一次资本化会挂到别的机器的判断上。
                IF v_maint.equipment_id IS DISTINCT FROM v_append_id THEN
                    RAISE EXCEPTION 'MAINTENANCE_ASSET_MISMATCH|%|%', v_target.code, p_maintenance_id;
                END IF;
                -- 【判断必须已经做过】capitalised = false 意味着没有人说过这是资本化。
                -- 表上那条 CHECK 保证 capitalised ⇒ 理由非空,所以到这里理由必然有。
                IF NOT v_maint.capitalised THEN
                    RAISE EXCEPTION 'MAINTENANCE_NOT_CAPITALISED|%', p_maintenance_id
                      USING HINT = '这条维修记录没有被标成资本化 —— 先在机器页上把它标成资本化并写明理由';
                END IF;
                -- 【一条维修记录只资本化一次】否则同一次大修会被加两遍成本。
                IF v_maint.capitalised_expense_id IS NOT NULL THEN
                    RAISE EXCEPTION 'MAINTENANCE_ALREADY_CAPITALISED|%|%',
                        p_maintenance_id, v_maint.capitalised_expense_id;
                END IF;
            ELSIF p_maintenance_id IS NOT NULL THEN
                -- 还没投用的机器不需要这条路 —— 成本本来就加得上去。
                -- 悄悄忽略这个参数会让调用方以为它起了作用。
                RAISE EXCEPTION 'MAINTENANCE_NOT_APPLICABLE|%', v_target.code
                  USING HINT = '这台机器还没投用,成本直接加得上去,不需要经维修记录';
            END IF;

            -- 每一笔追加带【自己的】三件套:原币金额、它自己那天的汇率、本位币额。
            -- 表头那三列是【第一笔】的(购置那一笔),不是合计 —— 合计只有
            -- cost_base 一个数,而各笔的原币可以不同(进口机器 USD、本地运费 SGD)。
            INSERT INTO fixed_asset_cost_entries
                (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
            VALUES (v_append_id, v_expense_id, v_cost_ccy, p_currency, v_fx, v_cost_base, v_user);

            UPDATE fixed_assets
               SET cost_base = cost_base + v_cost_base
             WHERE id = v_append_id;

            -- ════════════════════════════════════════════════════════════════
            -- ★★【CAPEX-1:落一个折旧锚点 —— 这里就是回溯补提被挡住的地方】★★
            --
            -- 上面那句 UPDATE 刚把 cost_base 抬高了。**如果什么都不做**,
            -- 月度例程下一次跑就会用新成本把【每一个已经过去的月份】的目标重算,
            -- 整笔补提落在本期 —— 那正是 4.7 明令禁止的。
            --
            -- 锚点把"过去那一段"冻成一个数:
            --   · pre_anchor_target_base = 按【锚点之前】那套算术、到锚点前一天
            --     为止【应当】累计多少。**注意是"应当",不是"已经提了多少"** ——
            --     欠着的那几期仍要按【旧费率】补上(delta = target − 已提 自动做到),
            --     不该被卷进新费率里摊掉。
            --   · remaining_months = 现行那一段的剩余月数,减去它已经走掉的部分。
            --     递归地写:没有现行锚点时,现行那一段就是"从投用日起、共 useful_life
            --     个月",于是这条式子对首次与第二次资本化是同一条。
            --
            -- 【生效日取当月 1 号】资本化落在哪个月,就从那个月末那一次起用新费率。
            IF v_target.in_service_date IS NOT NULL THEN
                v_anchor_from := date_trunc('month', p_expense_date)::date;

                SELECT * INTO v_prev FROM fixed_asset_depreciation_anchors an
                 WHERE an.asset_id = v_append_id AND an.effective_from <= v_anchor_from
                 ORDER BY an.effective_from DESC LIMIT 1;
                IF FOUND THEN
                    v_prev_start := v_prev.effective_from;
                    v_prev_rem   := v_prev.remaining_months;
                    -- 锚点之前那一段的目标 = 上一个常数 + 上一段走掉的部分
                    v_pre_target := v_prev.pre_anchor_target_base
                        + LEAST(round(v_target.cost_base - v_cost_base - v_target.residual_base
                                      - v_prev.pre_anchor_target_base, 2),
                                round((v_target.cost_base - v_cost_base - v_target.residual_base
                                       - v_prev.pre_anchor_target_base)
                                      / v_prev.remaining_months
                                      * depreciation_months_elapsed(v_prev_start, v_anchor_from - 1), 2));
                ELSE
                    v_prev_start := v_target.in_service_date;
                    v_prev_rem   := v_target.useful_life_months;
                    -- 【注意 cost_base 减回本次追加】v_target 是 UPDATE 之【前】读的那一行,
                    -- 所以它的 cost_base 本来就是旧值 —— 这里不减。写出来是因为
                    -- 下一个读的人会问:常数用的是【加钱之前】的成本吗?是。
                    v_pre_target := LEAST(
                        round(v_target.cost_base - v_target.residual_base, 2),
                        round((v_target.cost_base - v_target.residual_base)
                              / v_target.useful_life_months
                              * depreciation_months_elapsed(v_prev_start, v_anchor_from - 1), 2));
                END IF;

                v_rem := round(v_prev_rem
                               - depreciation_months_elapsed(v_prev_start, v_anchor_from - 1), 6);
                -- 【寿命走完的机器不许再资本化】剩余月数 ≤ 0 时那条公式的分母是零或负,
                -- 而它背后的现实是:一台已经提完的机器,再投的钱要么是当期费用,
                -- 要么需要先重估寿命 —— 两者都不是这条路。按名拒,不猜。
                IF v_rem <= 0 THEN
                    RAISE EXCEPTION 'ASSET_LIFE_EXHAUSTED|%|%', v_target.code, v_target.useful_life_months
                      USING HINT = '这台机器的使用年限已经走完,没有"剩余年限"可以摊 —— 这笔钱要么是当期费用,要么先要有一次使用年限重估(那一条还没有建,见 docs/known-issues.md)';
                END IF;

                INSERT INTO fixed_asset_depreciation_anchors
                    (asset_id, effective_from, pre_anchor_target_base, remaining_months,
                     expense_id, maintenance_id, reason, created_by)
                VALUES (v_append_id, v_anchor_from, v_pre_target, v_rem,
                        v_expense_id, p_maintenance_id, v_maint.capitalisation_reason, v_user);

                -- 【回填 capitalised_expense_id —— 1.5 找到的那个缺口在这里闭合】
                -- 在此之前没有任何一条代码路径写过这一列,因为这笔支出建不出来。
                UPDATE equipment_maintenance
                   SET capitalised_expense_id = v_expense_id
                 WHERE id = p_maintenance_id;
            END IF;

            RETURN jsonb_build_object(
                'expense_id', v_expense_id,
                'asset_id', v_append_id, 'asset_code', v_target.code,
                'asset_mode', 'append',
                -- CAPEX-1:把锚点回给调用方 —— 屏幕要说得出"从这个月起按新费率摊,
                -- 还剩几个月",而不是让页面自己再算一遍。
                'anchor_from', v_anchor_from,
                'anchor_remaining_months', v_rem,
                'journal_entry_id', (v_je->>'entry_id')::uuid,
                'journal_code', v_je->>'code',
                'code', v_code);
        END IF;

        -- ── 新建(FIN-22 起的原样路径)──────────────────────────────────────
        -- 【两扇建卡的门,而【两扇都不是遗留】—— EQP-1c-a 记在这里,免得下一个
        --   读到 create_fixed_asset 的人以为这一支该被删掉。】
        --   * 这一支(卡与成本【同时】诞生):一台【没有采购单、当场买断】的机器。
        --     那件事的真实形状就是"一张发票同时带来这台机器和它的成本",
        --     硬要拆成两步反而是编造一个不存在的中间状态。
        --   * create_fixed_asset(卡先诞生、成本后到):设备采购的常态 ——
        --     先下单(而采购单行必须引用一张【已存在】的卡,EQP-1a),
        --     后开票。发票经【追加】模式落到那张卡上。
        --   判据一句话:**这台机器在拿到它的成本之前,需不需要先被别的单据引用?**
        --   需要 → create_fixed_asset;不需要 → 这一支。
        IF COALESCE(p_asset->>'description', '') = '' THEN
            RAISE EXCEPTION 'ASSET_DESCRIPTION_REQUIRED';
        END IF;
        v_life := (p_asset->>'useful_life_months')::integer;
        IF v_life IS NULL OR v_life <= 0 THEN
            RAISE EXCEPTION 'ASSET_LIFE_INVALID|%', COALESCE(p_asset->>'useful_life_months', '?');
        END IF;
        v_residual := COALESCE((p_asset->>'residual_base')::numeric, 0);
        IF v_residual < 0 OR v_residual >= v_cost_base THEN
            RAISE EXCEPTION 'ASSET_RESIDUAL_INVALID|%|%', v_residual, v_cost_base;
        END IF;
        v_in_service := (p_asset->>'in_service_date')::date;
        IF v_in_service IS NOT NULL AND v_in_service < p_expense_date THEN
            RAISE EXCEPTION 'ASSET_IN_SERVICE_BEFORE_ACQUISITION|%|%', v_in_service, p_expense_date;
        END IF;

        v_asset_id := gen_random_uuid();
        -- EQP-1c-a:取号提成 next_fixed_asset_code(),两扇门共用一个号段。
        -- 【行为逐字不变】它就是原来这四行:同一把咨询锁(键也是按年拼的
        -- 'fixed_asset_code_'||year)、同一个"当年最大号 + 1"。提出来是因为
        -- 现在有【两扇】建卡的门,而两份同样的取号逻辑迟早会漂开。
        v_asset_code := next_fixed_asset_code(p_expense_date);

        INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date,
                                  cost_ccy, currency, fx_rate, cost_base, useful_life_months,
                                  residual_base, depreciation_account_code, expense_id, notes, created_by)
        VALUES (v_asset_id, v_asset_code, p_asset->>'description',
                COALESCE(p_asset->>'category', 'equipment'),
                p_expense_date, v_in_service,
                v_cost_ccy, p_currency, v_fx, v_cost_base, v_life,
                v_residual, COALESCE(p_asset->>'depreciation_account_code', '6700'),
                v_expense_id, p_asset->>'notes', v_user);

        -- 【第一笔也进明细表】否则"这台机器的成本由哪几笔构成"对第一笔要查
        -- expenses、对后续几笔要查明细表 —— 两处读法,迟早各说各话。
        INSERT INTO fixed_asset_cost_entries
            (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
        VALUES (v_asset_id, v_expense_id, v_cost_ccy, p_currency, v_fx, v_cost_base, v_user);
    END IF;

    RETURN jsonb_build_object(
        'expense_id', v_expense_id,
        'asset_id', v_asset_id, 'asset_code', v_asset_code,
        'code', v_code,
        'amount_base', v_amount_base,
        'journal_code', v_je->>'code',
        'payment_status', p_payment_status,
        -- WHT-1:把裁定回给调用方,让屏幕说得出"这张单付的时候会扣多少" ——
        -- 而不是让页面自己再乘一遍(那就是第二份实现)。
        'wht_nature', v_wht_nature,
        'wht_rate_pct', CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_rate END,
        'wht_amount_ccy', CASE WHEN v_wht_nature IS NULL THEN 0 ELSE v_wht_ccy END,
        'currency', p_currency
    );
END;
$function$
;

-- ═══ db/views/expense_claim_status.sql ═══
-- db/views/expense_claim_status.sql
-- CLAIM-1：每一笔报销一行，而「付了没有」是从核销额【推导】出来的。
--
-- ★ WITH (security_invoker = off) 与 COMMENT ON VIEW 都是【手工补回来的】★
-- pg_get_viewdef() 只吐 SELECT —— 既不吐 reloptions，也不吐对象注释。
-- 照它重建镜像会把两样都悄悄丢掉（AGENTS.md 为前者记过一次；后者是
-- STATEMENT-1 漏过、CHASE-1-FU 补上的那一条）。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ APR-ROUTE-1 · F1(Tim 的 R5,2026-09-23):这张视图此前把【每一笔】报销
--     交给【任何一个】登录的人 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它是什么形状】属主权限(security_invoker = off),于是 expense_claims 的 RLS
-- 根本不参与;而函数体【没有任何行谓词】。EMP-SELF-0 §3 以 fusheng(warehouse,
-- 不持 module.finance.view)的真身份实测:看得见 4 行 —— 线上全部 4 行,
-- 跨 2 名员工,带姓名、金额、事由。/me 只是因为页面自己加了
-- `.eq('employee_id', …)` 才没有在屏幕上露出来 —— 一道只在【页面】上的过滤,
-- 对一个直接调 PostgREST 的人什么都不是。
--
-- 【谓词】与 medical_claim_status 逐字同形:财务看全部,其余每个人只看自己的。
--   has_permission('module.finance.view') OR employee_id = current_user_employee()
-- ★ 两个都按【调用者】求值(两者都是 SECURITY DEFINER、读 auth.uid()),
--   所以属主权限不会把它们变成"属主看得见的一切"。
--
-- 【下面 COD-2 那段理由,在这张视图上是【假】的,照直更正】它说"本视图要喂
-- operations_now,加谓词会让没有财务权限的人的行静默消失"。EMP-SELF-0 §3 与
-- APR-ROUTE-1 grilling 各查一遍:`grep expense_claim_status` 在 db/views、
-- db/functions、app、lib 里只命中两处 —— app/me/page.tsx(本人)与
-- app/finance/claims/page.tsx(页闸 module.finance.view)。**没有任何视图或函数
-- 读它。** 于是这一句谓词没有让任何一个合法读者少一行。
-- ☞ 那段话大概是从 collection_promise_status(同一次 COD-2 一起收权的另一张)
--   上抄过来的。它留在下面,因为 REVOKE FROM anon 那一句仍然对 —— 错的只是理由。
--
-- 【一个读者真的少了行:db/fixtures/196 的 F0b】它以 postgres、清空 claims 的身份
-- 读这张视图来自证"视图里有东西"。postgres 没有 JWT → has_permission 恒假、
-- current_user_employee() 为 NULL → 0 行 → F0b 响亮地报"前提不成立"。
-- 同一刀里改成以一个持 module.finance.view 的身份读(Tim 的 Q11)。
--
-- NOTE: introduced by db/migrations/2026-08-28-claim1-employee-expense-claims.sql.

-- AP-RECON-1(2026-09-24):「付清了没有」对着【净额 + 进项税】判(expense_payable_ccy)——
-- 那是总账 2000 上欠员工的全部;只对着净额判,会在那笔税还欠着的时候说"已付"。
-- (报销的税是【加在】报销额之上还是【从里面拆出来】,是另一件事,Tim 裁定为
--  AP-RECON-1 之后紧接的一刀,见 docs/forward-queue.md 头条。)

CREATE OR REPLACE VIEW public.expense_claim_status WITH (security_invoker = off) AS
SELECT c.id AS claim_id,
    c.code,
    c.employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    c.spend_date,
    c.submitted_at,
    c.amount_ccy,
    c.currency,
    c.description,
    c.no_receipt_reason,
    c.status,
    c.decided_at,
    c.decision_notes,
    c.account_code,
    c.tax_code,
    c.posting_date,
    c.expense_id,
    x.payment_status,
    x.status = 'reversed'::text AS expense_reversed,
    COALESCE(a.settled_ccy, 0::numeric) AS settled_ccy,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) >= expense_payable_ccy(x.amount_ccy, x.tax_rate_pct) AS is_paid,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) < expense_payable_ccy(x.amount_ccy, x.tax_rate_pct) AS is_owing,
    (EXISTS ( SELECT 1
           FROM finance_attachments fa
          WHERE fa.claim_id = c.id AND fa.deleted_at IS NULL)) AS has_receipt
   FROM expense_claims c
     JOIN employees e ON e.id = c.employee_id
     LEFT JOIN expenses x ON x.id = c.expense_id
     LEFT JOIN LATERAL ( SELECT round(sum(pa.allocated_ccy), 2) AS settled_ccy
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id
          WHERE pa.expense_id = c.expense_id AND p.status = 'posted'::text) a ON true
  WHERE has_permission('module.finance.view'::text) OR c.employee_id = current_user_employee();

COMMENT ON VIEW public.expense_claim_status IS
    'CLAIM-1:每一笔报销一行,而【付了没有是推导出来的】—— 与 medical_claim_status 同一条:付款状态归 expenses 所有,存一份副本第一次冲销付款时两边就分家。expense_reversed 单独露出来,因为"批准被撤销"在本刀里【没有】自己的机制:改法是冲销那笔费用(expenses 本来就有冲销路径与 reversed_by_expense),claim 的状态跟着它走 —— 两个撤销机制会对"这笔钱还欠不欠"各说各话。属主权限(security_invoker = off):它横跨 finance 与 hr(employees 有 RLS),invoker 会让读者无权的那一侧静默丢掉行,而行消失在这里意味着"少了一笔欠员工的钱"(OPS-14 修法 (a))。★ APR-ROUTE-1(F1,Tim 的 R5):行谓词写在视图里 —— has_permission(''module.finance.view'') OR employee_id = current_user_employee(),与 medical_claim_status 同形;此前它把每一笔报销交给任何一个登录的人,只靠页面自己的过滤挡着。';

-- ════════════════════════════════════════════════════════════════════════════
-- ★ COD-2(2026-09-08):从 anon 手里收回 —— 这一行必须在镜像里,不能只在迁移里 ★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它此前是什么状态】ANON-0 实测:本视图是属主权限(security_invoker = off,
-- 于是基表的 RLS 根本不参与)、授给了 anon、body 里没有任何权限判据、也不调
-- 任何带门的函数。**它今天回空只因为基表还没有行。** ANON-0 的原话:
-- 它不是在漏,它是【上了膛】—— 第一条真实记录写进来的那一刻它就开了,
-- 而在此之前没有任何检查会说一句话(check_mirrors.py 第 59 行自己写着「不比 GRANT」)。
--
-- 【为什么是 REVOKE,而不是给 body 加一句 has_permission】
--   本文件上面那段注释自己写着:它【刻意只有纯 SQL、一个函数都不调】,
--   因为它要喂 operations_now —— 那是没有财务权限的人也在看的首页。
--   加一句谓词会让那些人的行【静默消失】,而"少了一个逾期承诺"与"报错"
--   完全不是一回事。那正是 OPS-14 修法 (a) 要避开的东西。
--   而 REVOKE 对 authenticated 零代价:anon 从来不是它的合法读者。
--
-- 【为什么这一行住在镜像里】db/views/batch_lineage_all.sql 的抬头记着这个疤:
--   一条只住在迁移里的 REVOKE,重建出来的库【是开着的】——「线上收着,
--   重建出来的库开着」。看着它别再漂回去的是 db/check_grants.py(COD-2)。
REVOKE ALL ON public.expense_claim_status FROM anon;

-- ═══ db/views/medical_claim_status.sql ═══
-- db/views/medical_claim_status.sql
-- 医疗报销一览。HR 看全部,员工看自己的。
-- settlement_state 从【已过账的付款分配】推导 —— 与 ap_open_items 用同一个信号,
-- 因为 expenses.payment_status 对"建单时未付、之后经付款流程结清"的费用不会翻转。
--
-- NOTE: updated by db/migrations/2026-08-02-hr2b-leave-exceptions-and-claims.sql.

-- AP-RECON-1(2026-09-24):「付清」对着【净额 + 进项税】的本位币判(amount_base + tax_base,
-- 过账时存下的两个数)—— 与 ap_open_items 的费用支 doc_value_base 同一个数。

CREATE OR REPLACE VIEW public.medical_claim_status WITH (security_invoker = off) AS
 SELECT mc.id AS claim_id,
    mc.code,
    mc.employee_id,
    e.code AS employee_code,
    e.legal_name,
    mc.claim_date,
    mc.claim_year,
    mc.amount_sgd,
    mc.description,
    mc.receipt_ref,
    mc.status,
    mc.decided_at,
    mc.expense_id,
    mc.expense_id IS NOT NULL AS linked_to_expense,
    ex.code AS expense_code,
    ex.amount_base AS expense_amount_base,
    COALESCE(pay.settled_base, 0::numeric) AS settled_base,
        CASE
            WHEN mc.status <> 'approved'::text THEN mc.status
            WHEN mc.expense_id IS NULL THEN 'awaiting_payment_run'::text
            WHEN COALESCE(pay.settled_base, 0::numeric) >= (ex.amount_base + COALESCE(ex.tax_base, 0::numeric)) THEN 'paid'::text
            WHEN COALESCE(pay.settled_base, 0::numeric) > 0::numeric THEN 'part_paid'::text
            ELSE 'expense_raised'::text
        END AS settlement_state
   FROM medical_claims mc
     JOIN employees e ON e.id = mc.employee_id
     LEFT JOIN expenses ex ON ex.id = mc.expense_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled_base
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.expense_id = ex.id) pay ON true
  WHERE mc.deleted_at IS NULL AND (has_permission('module.hr.view'::text) OR mc.employee_id = current_user_employee());

-- ═══ db/views/ar_open_items.sql ═══
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

-- AGING-1(2026-08-27):四条档位边界改为调用 aging_bucket() —— 全库唯一一处定义。
-- 【列集一字未动】,所以迁移走 CREATE OR REPLACE,operations_now 一类的依赖不必 DROP。
-- 【WITH (security_invoker = off) 是手写补回去的】pg_get_viewdef 不吐 reloptions
-- (PAYEE-1a 为此记过一次账),照它重建会把属主权限悄悄丢掉 —— 行为不变,
-- 但下一个读镜像的人会据此判断这张视图是不是刻意声明过。
--
-- 【本页不再读它了,而它留着】/finance/receivables 改读 ar_aging_asof(as_of):
-- 一个 as-at 报表与一张"今天"的视图若各写一份档位边界,就是两份会漂开的实现。
-- 这张视图仍有别的消费方(看板 ar_over_90 等),所以留着;
-- db/fixtures/135 的 A 臂断言函数【截至今天】与它逐行逐列相同,两个方向差集都为空。

-- ═══════════════════════════════════════════════════════════════════════════
-- 【AP-RECON-1(2026-09-24):第三支 —— sale 型发票的销项税,doc_kind 'invoice_gst'】
-- create_invoice 给一笔直销开票时,【只过税】:借 1100 / 贷 2100,以【本位币】(即便那笔
-- 销售是 USD)。而第一支只认 数量×单价 —— 于是那笔税在 1100 上躺着、在应收上不存在,
-- 收款也核销不进去(INV-2026-0009 的 102.87,AR 侧的类别 C)。
-- Tim AP-RECON-1 Q5:这笔税是【它自己的一项应收】,本位币,上限就是它的税额;
-- 销售那一行照旧以自己的币种列着。两行按构造不相交:净额只核销到 sales_record_id,
-- 税只核销到 invoice_id(record_payment_internal 的发票支)。
-- 【为什么不把税折进销售那一行】USD 销售上的本位币税要折成 USD 才加得进去,那一折是有损的,
-- 而且会让同一张单据带两种币。单独一行,数与过账时存下的 invoices.tax_base 逐分相同。
-- 门与第二支同:finance.view + data.view_prices。作废的发票不列(它的税已随作废冲回)。
-- ═══════════════════════════════════════════════════════════════════════════

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
    aging_bucket(CURRENT_DATE - sr.sale_date) AS bucket,
    inv.invoice_id,
    inv.invoice_code,
    'sale'::text AS doc_kind,
    round(COALESCE(s.settled, 0::numeric) * sr.fx_rate, 2) AS settled_base,
    0::numeric AS credited_ccy,
    0::numeric AS credited_base
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
  WHERE round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) > 0::numeric AND sr.sales_order_line_id IS NULL AND has_permission('module.finance.view'::text)
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
    aging_bucket(CURRENT_DATE - o.issue_date) AS bucket,
    o.invoice_id,
    o.code AS invoice_code,
    'invoice'::text AS doc_kind,
    round(o.settled_ccy * o.fx_rate, 2) AS settled_base,
    o.credited_ccy,
    o.credited_base
   FROM order_invoice_open_all o
     LEFT JOIN customers c ON c.id = o.customer_id
  WHERE has_permission('module.finance.view'::text) AND has_permission('data.view_prices'::text)
UNION ALL
 SELECT NULL::uuid AS sales_record_id,
    i.code AS doc_code,
    i.customer_id,
    c.legal_name AS customer_name,
    i.issue_date AS sale_date,
    i.tax_base AS amount_base,
    ( SELECT cur.code
           FROM currencies cur
          WHERE cur.is_base) AS currency,
    i.tax_base AS amount_ccy,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_ccy,
    round(i.tax_base - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
    round(i.tax_base - COALESCE(s.settled, 0::numeric), 2) AS open_base,
    CURRENT_DATE - i.issue_date AS days_outstanding,
    aging_bucket(CURRENT_DATE - i.issue_date) AS bucket,
    i.id AS invoice_id,
    i.code AS invoice_code,
    'invoice_gst'::text AS doc_kind,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_base,
    0::numeric AS credited_ccy,
    0::numeric AS credited_base
   FROM invoices i
     LEFT JOIN customers c ON c.id = i.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.invoice_id = i.id) s ON true
  WHERE i.kind = 'sale'::text AND i.status = 'issued'::text AND i.tax_base > 0::numeric AND round(i.tax_base - COALESCE(s.settled, 0::numeric), 2) > 0::numeric AND has_permission('module.finance.view'::text) AND has_permission('data.view_prices'::text);

-- ═══ db/functions/ar_aging_asof.sql ═══
-- db/functions/ar_aging_asof.sql
-- AGING-1(2026-08-27):AR 账龄【截至某一天】。两支:直接销售记录 + 订单流发票。
--
-- 【第二支把 order_invoice_balance_all 的算术抄了下来,而不是引用它】
-- 那张视图算的是"现在":已结只认 posted 收款、已贷记不问贷项日、发票在不在只看
-- status。三处都要按 D 回推,而【视图接不了参数】—— 这正是本刀存在的理由本身,
-- 在第二支上再出现一次。**两处注释互指:一边改了,另一边必须跟着改。**
--
-- 【到期日只是一列,档位仍按单据日】实测 invoices.due_date 6/6 已填,而供应商
-- 0/8、客户 0/3 填了账期 —— 让一份报表里一支的"账龄"意思是"逾期"、另外四支是
-- "开出至今",比整份都不精确更坏。Tim 2026-08-27 裁定。
--
-- NOTE: introduced by db/migrations/2026-08-27-aging1-as-at-a-date.sql.

CREATE OR REPLACE FUNCTION public.ar_aging_asof(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_as_of   date;
    v_today   date := CURRENT_DATE;
    v_start   date;
    v_base    text;
    v_rows    jsonb;
    v_buckets jsonb;
    v_total   numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    v_as_of := COALESCE(p_as_of, v_today);

    IF v_as_of > v_today THEN
        RAISE EXCEPTION 'AGING_AS_OF_FUTURE|%|%', v_as_of, v_today;
    END IF;

    SELECT fs.system_start_date INTO v_start FROM finance_settings fs LIMIT 1;
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.sale_date, x.doc_code), '[]'::jsonb)
      INTO v_rows
      FROM (
        -- ── 支一:直接销售记录 ─────────────────────────────────────────
        SELECT sr.id                                     AS sales_record_id,
               ob.code                                   AS doc_code,
               sr.customer_id                            AS customer_id,
               c.legal_name                              AS customer_name,
               sr.sale_date                              AS sale_date,
               -- 销售支的到期日:它自己没有,但它挂着的那张【在册】发票有。
               -- 实测 invoices.due_date 6/6 已填,所以这一列在 AR 上是有内容的。
               inv.due_date                              AS due_date,
               sr.amount_base                            AS amount_base,
               sr.currency                               AS currency,
               round(sr.quantity * sr.unit_price, 2)     AS amount_ccy,
               round(COALESCE(s.settled, 0), 2)          AS settled_ccy,
               round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0), 2) AS open_ccy,
               round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0)) * sr.fx_rate, 2) AS open_base,
               (v_as_of - sr.sale_date)                  AS days_outstanding,
               aging_bucket(v_as_of - sr.sale_date)      AS bucket,
               inv.invoice_id                            AS invoice_id,
               inv.invoice_code                          AS invoice_code,
               'sale'::text                              AS doc_kind,
               round(COALESCE(s.settled, 0) * sr.fx_rate, 2) AS settled_base,
               0::numeric                                AS credited_ccy,
               0::numeric                                AS credited_base
          FROM sales_records_masked sr
          JOIN output_batches ob ON ob.id = sr.output_batch_id
          LEFT JOIN customers c ON c.id = sr.customer_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.sales_record_id = sr.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT i.id AS invoice_id, i.code AS invoice_code, i.due_date
                  FROM invoice_lines_masked il
                  JOIN invoices_masked i ON i.id = il.invoice_id
                 WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
                 LIMIT 1
          ) inv ON true
         WHERE sr.sale_date <= v_as_of
           AND sr.sales_order_line_id IS NULL

        UNION ALL

        -- ── 支二:订单流发票 ───────────────────────────────────────────
        -- 【为什么这里把 order_invoice_balance_all 的算术抄了下来,而不是引用它】
        -- 那张视图是"现在"的算术:已结只认 posted 收款、已贷记不问贷项日、
        -- 发票在不在只看 status。三处都要按 D 回推,而【视图接不了参数】——
        -- 这正是本刀存在的理由本身,在第二支上再出现一次。
        -- 算术本身逐列同源,任何一边改了另一边必须跟着改,两处注释互指。
        SELECT NULL::uuid, i.code, i.customer_id, c.legal_name,
               i.issue_date, i.due_date,
               round(l.amount_ccy * i.fx_rate, 2),
               i.currency, l.amount_ccy,
               round(COALESCE(s.settled, 0), 2),
               round(l.amount_ccy - COALESCE(s.settled, 0) - COALESCE(cn.credited, 0), 2),
               round((l.amount_ccy - COALESCE(s.settled, 0) - COALESCE(cn.credited, 0)) * i.fx_rate, 2),
               (v_as_of - i.issue_date),
               aging_bucket(v_as_of - i.issue_date),
               i.id, i.code, 'invoice'::text,
               round(COALESCE(s.settled, 0) * i.fx_rate, 2),
               round(COALESCE(cn.credited, 0), 2),
               round(COALESCE(cn.credited, 0) * i.fx_rate, 2)
          FROM invoices i
          LEFT JOIN customers c ON c.id = i.customer_id
          JOIN LATERAL (
                SELECT COALESCE(sum(il.amount_ccy), 0) AS amount_ccy
                  FROM invoice_lines il WHERE il.invoice_id = i.id
          ) l ON true
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.invoice_id = i.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                -- 贷项凭证有自己的业务日(note_date),所以它照 D 截断,
                -- 与收款同一条:D 之后开的贷项凭证不往回渗。
                SELECT sum(cl.amount) AS credited
                  FROM credit_note_lines cl
                  JOIN credit_notes cc ON cc.id = cl.credit_note_id
                 WHERE cc.invoice_id = i.id AND cc.note_date <= v_as_of
          ) cn ON true
         WHERE i.kind = 'order'
           AND i.issue_date <= v_as_of
           -- 作废日优先取【那张冲销分录的分录日】(void_invoice 的 p_reversal_date
           -- 就是它),取不到才退回 voided_at 的录入时刻。
           AND (i.status = 'issued'
                OR (i.status = 'void'
                    AND COALESCE((SELECT r.entry_date
                                    FROM journal_entries o
                                    JOIN journal_entries r ON r.id = o.reversed_by
                                   WHERE o.id = i.entry_id),
                                 i.voided_at::date) > v_as_of))
           -- 第二支与今天那张视图同效:显式要 data.view_prices。
           -- 第一支靠 sales_records_masked 把 unit_price 遮成 NULL 自然消失,
           -- 两支对同一读者同进同退。
           AND has_permission('data.view_prices')

        UNION ALL

        -- ── AP-RECON-1:第三支 —— sale 型发票的销项税(与 ar_open_items 第三支同义)──
        -- 本位币、上限即税额;在不在与作废的回推逐字照抄第二支(作废分录的分录日),
        -- 结清按收款日回推与前两支同一条。
        SELECT NULL::uuid, i.code, i.customer_id, c.legal_name,
               i.issue_date, i.due_date,
               i.tax_base,
               v_base, i.tax_base,
               round(COALESCE(s.settled, 0), 2),
               round(i.tax_base - COALESCE(s.settled, 0), 2),
               round(i.tax_base - COALESCE(s.settled, 0), 2),
               (v_as_of - i.issue_date),
               aging_bucket(v_as_of - i.issue_date),
               i.id, i.code, 'invoice_gst'::text,
               round(COALESCE(s.settled, 0), 2),
               0::numeric,
               0::numeric
          FROM invoices i
          LEFT JOIN customers c ON c.id = i.customer_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.invoice_id = i.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
         WHERE i.kind = 'sale'
           AND i.tax_base > 0
           AND i.issue_date <= v_as_of
           AND (i.status = 'issued'
                OR (i.status = 'void'
                    AND COALESCE((SELECT r.entry_date
                                    FROM journal_entries o
                                    JOIN journal_entries r ON r.id = o.reversed_by
                                   WHERE o.id = i.entry_id),
                                 i.voided_at::date) > v_as_of))
           AND has_permission('data.view_prices')
      ) x
     WHERE x.open_ccy > 0;

    SELECT jsonb_object_agg(b.bucket, COALESCE(agg.total, 0))
      INTO v_buckets
      FROM (VALUES ('b0_30'), ('b31_60'), ('b61_90'), ('b90_plus')) AS b(bucket)
      LEFT JOIN LATERAL (
            SELECT round(sum((e->>'open_base')::numeric), 2) AS total
              FROM jsonb_array_elements(v_rows) e
             WHERE e->>'bucket' = b.bucket
      ) agg ON true;

    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0)
      INTO v_total FROM jsonb_array_elements(v_rows) e;

    RETURN jsonb_build_object(
        'side',                'ar',
        'as_of',               v_as_of,
        'today',               v_today,
        'is_past',             (v_as_of < v_today),
        'system_start_date',   v_start,
        'before_system_start', (v_start IS NOT NULL AND v_as_of < v_start),
        'base_currency',       v_base,
        -- AR 两支的金额都是【冻住的】(销售记录的量价、发票行的生成列),
        -- 没有 AP 那个"数量按今天"的近似,所以基准令牌不同。
        'amount_basis',        'amounts_as_recorded',
        'unpriced_excluded',   NULL,
        'total_open_base',     v_total,
        'buckets',             v_buckets,
        'rows',                v_rows
    );
END;
$function$;

COMMENT ON FUNCTION public.ar_aging_asof(date) IS
    'AGING-1:AR 账龄【截至某一天】。三支:直接销售记录 + 订单流发票 + sale 型发票的销项税(AP-RECON-1,本位币,与 ar_open_items 第三支同义)。结清按收款日回推、贷记按 note_date 回推、发票在不在按【作废分录的分录日】回推(晚于 D 的作废不回溯)。第二支把 order_invoice_balance_all 的算术抄了下来而不是引用它 —— 那张视图是「现在」的算术且接不了参数,正是本刀存在的理由再出现一次;两处注释互指,一边改另一边必须跟着改。到期日:发票支取 invoices.due_date,销售支取它挂着的在册发票的 due_date(实测 6/6 已填);【档位仍按单据日,不按到期日】。p_as_of 默认今天,等于今天时逐行复现今天那张视图 —— db/fixtures/135 的 A 臂钉住。';

-- ═══ db/functions/customer_ar_exposure_base.sql ═══
CREATE OR REPLACE FUNCTION public.customer_ar_exposure_base(p_customer_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- SO-3a:敞口 = 未结清销售 + 【已过账未结清的订单流发票】。第二项读
    -- order_invoice_open_all —— ar_open_items 的第二支读的也是它:面板显示的
    -- 余额与拒绝的那道闸必须是同一个数(fixture 67 的目录断言钉住两个消费者)。
    -- 两项按构造不相交:发货(3b)产生的销售记录不带应收,第一项看不见它们。
    SELECT COALESCE((
        SELECT sum(open_base) FROM (
            SELECT round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0)) * sr.fx_rate, 2) AS open_base
            FROM sales_records sr
            LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.sales_record_id = sr.id
            ) s ON true
            WHERE sr.customer_id = p_customer_id
              -- SO-3b:发货产生的销售记录【不带应收】—— 那笔债在开票当刻已经
              -- 记过(借 1100 / 贷 2500)。与 ar_open_items 第一支逐字同一条谓词:
              -- 少了它,同一笔钱会在敞口里被数两遍。
              AND sr.sales_order_line_id IS NULL
              AND round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0), 2) > 0
        ) x), 0)
    + COALESCE((
        SELECT sum(o.open_base) FROM order_invoice_open_all o
        WHERE o.customer_id = p_customer_id), 0)
    -- AP-RECON-1:第三项 —— sale 型发票上【未收的销项税】(本位币)。它在 1100 上,
    -- 客户欠着它,ar_open_items 的第三支列着它;敞口不算它,面板与闸就会比账龄少一截。
    + COALESCE((
        SELECT sum(round(i.tax_base - COALESCE(s.settled, 0), 2))
        FROM invoices i
        LEFT JOIN LATERAL (
            SELECT sum(pa.allocated_ccy) AS settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.invoice_id = i.id
        ) s ON true
        WHERE i.customer_id = p_customer_id
          AND i.kind = 'sale' AND i.status = 'issued' AND i.tax_base > 0
          AND round(i.tax_base - COALESCE(s.settled, 0), 2) > 0), 0);
$function$

;

-- ═══ db/functions/customer_statement_data.sql ═══
CREATE OR REPLACE FUNCTION public.customer_statement_data(p_customer_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        customers%ROWTYPE;
    v_base     text;
    v_open     jsonb;
    v_close    jsonb;
    v_opening  numeric;
    v_closing  numeric;
    v_charges  numeric;
    v_credits  numeric;
    v_receipts numeric;
    v_applied  numeric;
    v_onaccount numeric;
    v_lines    jsonb;
    v_byccy    jsonb;
    v_buckets  jsonb;
    v_diff     numeric;
BEGIN
    PERFORM require_permission('module.finance.view');

    SELECT * INTO v_c FROM customers WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'STATEMENT_PERIOD_REQUIRED';
    END IF;
    IF p_to < p_from THEN
        RAISE EXCEPTION 'STATEMENT_PERIOD_INVALID|%|%', p_from::text, p_to::text;
    END IF;
    -- 【未来的期末不给出】与 ar_aging_asof 的 AGING_AS_OF_FUTURE 同一条:
    -- 一份"截至下个月"的对账单不是一份对账单,是一次推测。
    IF p_to > CURRENT_DATE THEN
        RAISE EXCEPTION 'STATEMENT_PERIOD_FUTURE|%|%', p_to::text, CURRENT_DATE::text;
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 期初 = 截至【期间开始的前一天】那个客户还欠的;期末 = 截至期末。
    v_open  := ar_aging_asof(p_from - 1);
    v_close := ar_aging_asof(p_to);

    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0) INTO v_opening
      FROM jsonb_array_elements(v_open->'rows') e
     WHERE (e->>'customer_id') = p_customer_id::text;
    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0) INTO v_closing
      FROM jsonb_array_elements(v_close->'rows') e
     WHERE (e->>'customer_id') = p_customer_id::text;

    -- ══ 期间内的发生额 —— 三支,全部来自基表(与上面两个数是【两份独立推导】)══
    -- 【收款的"站着没有"判据必须与 ar_aging_asof 同源】一笔在期末之后才被冲销的
    -- 收款,在期末那天是算数的。两边不同源,那条勾稽等式就会莫名其妙地对不上 ——
    -- 而它对不上的时候会 STATEMENT_DOES_NOT_TIE 按名拒,不会悄悄寄出去。
    -- ★【收款 ≠ 核销 —— 这一条是实测出来的,不是设计出来的】★
    -- 第一版把"期间内的收款"直接减进等式,而它在【七月】对不上,两个客户各差
    -- 一笔:RCPT-2026-0003(USD 2,800)与 RCPT-2026-0001(USD 250)——
    -- 两笔都是【收了钱但一行核销都没有】的挂账收款。
    -- `ar_aging_asof` 的期末是【各张单据未结额之和】,而一笔挂在账上的钱
    -- 【没有减少任何一张单据】,所以它不改变期末余额。
    -- 于是勾稽用的必须是【核销额】,不是收款额;而收款额仍然要显示 ——
    -- 客户确实付了钱,一份不提这笔钱的对账单是错的。
    --
    -- 【顺带证明了 as-at 那一半是对的】同一段期间里 RCPT-2026-0002 是
    -- 【7-30 收、7-29 冲销】,它被正确地排除在外 —— 排除它的正是下面这条
    -- 与 ar_aging_asof 同源的"在期末那天站着没有"判据。
    SELECT COALESCE(round(sum(
               CASE WHEN p.currency = v_base THEN p.amount_ccy
                    ELSE round(p.amount_ccy * p.fx_rate, 2) END), 2), 0)
      INTO v_receipts
      FROM payments p
      LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
     WHERE p.customer_id = p_customer_id
       AND p.direction = 'in'
       AND p.payment_date BETWEEN p_from AND p_to
       AND (p.status = 'posted'
            OR (p.status = 'reversed' AND rev.payment_date > p_to));

    -- 核销额:期间内收款【真的抵掉单据】的那一部分,按单据自己的入账汇率折本位币
    -- —— 与 ar_aging_asof 的 settled_base 同一口径,所以两边【能够】对上;
    -- 而它走的是 payment_allocations 这条路,与那支函数按单据算未结额【不是同一次推导】,
    -- 所以它们【也能够】对不上 —— 那正是这条勾稽有意义的原因(OPS-17)。
    SELECT COALESCE(round(sum(
               CASE WHEN pa.sales_record_id IS NOT NULL THEN pa.allocated_ccy * sr.fx_rate
                    -- AP-RECON-1:sale 型发票只作为它那笔【本位币】销项税被核销 —— 汇率恒 1
                    -- (sale 型发票没有 fx_rate,乘它会得 NULL,整笔收款从"已核销"里静默消失)。
                    WHEN i.kind = 'sale' THEN pa.allocated_ccy
                    ELSE pa.allocated_ccy * i.fx_rate END), 2), 0)
      INTO v_applied
      FROM payment_allocations pa
      JOIN payments p ON p.id = pa.payment_id
      LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
      LEFT JOIN sales_records sr ON sr.id = pa.sales_record_id
      LEFT JOIN invoices i ON i.id = pa.invoice_id
     WHERE p.direction = 'in'
       AND p.payment_date BETWEEN p_from AND p_to
       AND (p.status = 'posted'
            OR (p.status = 'reversed' AND rev.payment_date > p_to))
       AND ((sr.id IS NOT NULL AND sr.customer_id = p_customer_id)
            OR (i.id IS NOT NULL AND i.customer_id = p_customer_id));

    -- 挂账余额(截至期末,累计):收到但还没抵到任何单据上的钱。
    -- 【为什么它要单独说】它不在期末余额里(那是单据未结额之和),但客户已经付了 ——
    -- 不说,对账单就少了一笔他确实付过的钱;混进期末余额,那个数就不再是
    -- 任何一张单据的和。所以它是【单独一行】,并据此给出"净欠"。
    SELECT COALESCE(round(sum(
               CASE WHEN p.currency = v_base
                    THEN p.amount_ccy - COALESCE(al.applied_pay, 0)
                    ELSE round((p.amount_ccy - COALESCE(al.applied_pay, 0)) * p.fx_rate, 2)
               END), 2), 0)
      INTO v_onaccount
      FROM payments p
      LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
      LEFT JOIN LATERAL (SELECT sum(pa.allocated_pay) AS applied_pay
                           FROM payment_allocations pa WHERE pa.payment_id = p.id) al ON true
     WHERE p.customer_id = p_customer_id
       AND p.direction = 'in'
       AND p.payment_date <= p_to
       AND (p.status = 'posted'
            OR (p.status = 'reversed' AND rev.payment_date > p_to));

    -- 贷项凭证:按 note_date 落期,挂在这个客户的发票上
    -- 【口径必须与账龄那一侧【逐条同源】,否则等式会因为一个筛子不同而对不上】
    -- 账龄的贷记只算在【order 型、且在期末那天仍然在册】的发票上
    -- (order_invoice_balance_all 的 kind='order';作废按【作废分录的分录日】回推)。
    -- 少任何一条,一张期末之前就作废了的发票上的贷项凭证会只出现在这一侧,
    -- 而它出现的方式是【等式差了那么多】—— 那时 STATEMENT_DOES_NOT_TIE 会拦住它,
    -- 但拦住不等于对:该做的是两边问同一个问题。
    SELECT COALESCE(round(sum(cl.amount * cn.fx_rate), 2), 0) INTO v_credits
      FROM credit_note_lines cl
      JOIN credit_notes cn ON cn.id = cl.credit_note_id
      JOIN invoices i ON i.id = cn.invoice_id
     WHERE i.customer_id = p_customer_id
       AND i.kind = 'order'
       AND cn.note_date BETWEEN p_from AND p_to
       AND (i.status = 'issued'
            OR (i.status = 'void'
                AND COALESCE((SELECT r.entry_date FROM journal_entries o
                                JOIN journal_entries r ON r.id = o.reversed_by
                               WHERE o.id = i.entry_id),
                             i.voided_at::date) > p_to));

    -- 发生额:期间内的订单流发票 + 期间内的直接销售记录。
    -- 【两支互斥,与 ar_open_items 同一条谓词】发货产生的销售记录带着
    -- sales_order_line_id,那笔债在开票当刻已经记过,不能再记一次。
    SELECT COALESCE(round(
             (SELECT COALESCE(sum(round(l.amount_ccy * i.fx_rate, 2)), 0)
                FROM invoices i
                JOIN LATERAL (SELECT COALESCE(sum(il.amount_ccy),0) AS amount_ccy
                                FROM invoice_lines il WHERE il.invoice_id = i.id) l ON true
               WHERE i.customer_id = p_customer_id AND i.kind = 'order'
                 AND i.issue_date BETWEEN p_from AND p_to
                 -- 同上:在期末那天【还站着】的才算发生额,而不是"今天还没作废的"
                 AND (i.status = 'issued'
                      OR (i.status = 'void'
                          AND COALESCE((SELECT r.entry_date FROM journal_entries o
                                          JOIN journal_entries r ON r.id = o.reversed_by
                                         WHERE o.id = i.entry_id),
                                       i.voided_at::date) > p_to)))
           + (SELECT COALESCE(sum(sr.amount_base), 0)
                FROM sales_records sr
               WHERE sr.customer_id = p_customer_id
                 AND sr.sales_order_line_id IS NULL
                 AND sr.sale_date BETWEEN p_from AND p_to)
           -- AP-RECON-1:sale 型发票的销项税是一笔【发生】—— 账龄的第三支列着它,
           -- 对账单不把它算进发生额,期初 + 发生 − 收款 就对不上期末(不寄)。
           -- 在不在与作废的回推照抄订单流发票那一项。
           + (SELECT COALESCE(sum(i.tax_base), 0)
                FROM invoices i
               WHERE i.customer_id = p_customer_id AND i.kind = 'sale' AND i.tax_base > 0
                 AND i.issue_date BETWEEN p_from AND p_to
                 AND (i.status = 'issued'
                      OR (i.status = 'void'
                          AND COALESCE((SELECT r.entry_date FROM journal_entries o
                                          JOIN journal_entries r ON r.id = o.reversed_by
                                         WHERE o.id = i.entry_id),
                                       i.voided_at::date) > p_to))), 2), 0)
      INTO v_charges;

    -- ══ 勾稽:两份独立推导必须相等 ══════════════════════════════════════════
    -- ★ 勾稽用【核销额】,不是收款额(见上面那一段实测)
    v_diff := round(v_opening + v_charges - v_credits - v_applied - v_closing, 2);

    -- 明细行:期末仍未结清的每一张单据(读 ar_aging_asof,不自己分档)
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'doc_kind',  e->>'doc_kind',
               'doc_code',  e->>'doc_code',
               'doc_date',  e->>'sale_date',
               'due_date',  e->>'due_date',
               'currency',  e->>'currency',
               'amount_ccy', (e->>'amount_ccy')::numeric,
               'open_ccy',  (e->>'open_ccy')::numeric,
               'open_base', (e->>'open_base')::numeric,
               'days_outstanding', (e->>'days_outstanding')::int,
               'bucket',    e->>'bucket'
           ) ORDER BY (e->>'sale_date')::date, e->>'doc_code'), '[]'::jsonb)
      INTO v_lines
      FROM jsonb_array_elements(v_close->'rows') e
     WHERE (e->>'customer_id') = p_customer_id::text;

    -- 每币种一段
    SELECT COALESCE(jsonb_agg(x ORDER BY x.currency), '[]'::jsonb) INTO v_byccy
      FROM (
        SELECT ccy AS currency,
               round(sum(open_ccy), 2) AS closing_ccy
          FROM (SELECT e->>'currency' AS ccy, (e->>'open_ccy')::numeric AS open_ccy
                  FROM jsonb_array_elements(v_close->'rows') e
                 WHERE (e->>'customer_id') = p_customer_id::text) q
         GROUP BY ccy
      ) x;

    -- 期末账龄四档:只数这个客户的
    SELECT jsonb_object_agg(b.bucket, COALESCE(agg.total, 0)) INTO v_buckets
      FROM (VALUES ('b0_30'), ('b31_60'), ('b61_90'), ('b90_plus')) AS b(bucket)
      LEFT JOIN LATERAL (
            SELECT round(sum((e->>'open_base')::numeric), 2) AS total
              FROM jsonb_array_elements(v_close->'rows') e
             WHERE (e->>'customer_id') = p_customer_id::text
               AND e->>'bucket' = b.bucket
      ) agg ON true;

    RETURN jsonb_build_object(
        'customer_id',   p_customer_id,
        'customer_code', v_c.code,
        'customer_name', v_c.legal_name,
        'period_start',  p_from,
        'period_end',    p_to,
        'base_currency', v_base,
        'opening_base',  v_opening,
        'charges_base',  v_charges,
        'credits_base',  v_credits,
        'receipts_base', v_receipts,
        'applied_base',  v_applied,
        'on_account_base', v_onaccount,
        -- 净欠 = 期末单据余额 − 挂在账上的钱。两个数都要给出来:
        -- 只给期末,客户会问"我付的那笔呢";只给净欠,它就不再等于任何单据之和。
        'net_due_base',  round(v_closing - v_onaccount, 2),
        'closing_base',  v_closing,
        'tie_difference', v_diff,
        'ties',          (v_diff = 0),
        -- 【期间内什么都没发生,是一个【有名字的状态】,不是一张空表】
        'no_movement',   (v_charges = 0 AND v_credits = 0 AND v_receipts = 0),
        'lines',         v_lines,
        'by_currency',   v_byccy,
        'buckets',       v_buckets);
END;
$function$

;

-- ═══ db/functions/void_invoice.sql ═══
CREATE OR REPLACE FUNCTION public.void_invoice(p_invoice_id uuid, p_reason text, p_reversal_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv invoices%ROWTYPE;
    v_n   int;
    v_rev jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'INVOICE_ALREADY_VOID|%', v_inv.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    IF v_inv.kind = 'order' THEN
        -- 【冲销日必填,永不默认】它决定冲销分录的期间;期间锁/年结闸由
        -- post_journal_entry 对它统一执行(锁住的月份按名拒,不是悄悄挪到今天)。
        IF p_reversal_date IS NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
        END IF;
        -- 【有活核销就不作废】核销行不可变、只随收款的冲销失效 —— 先冲收款
        -- (reverse_payment,先例),再作废发票。顺序反过来会留下一堆指着
        -- 已作废单据的活核销。
        SELECT count(*) INTO v_n
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.invoice_id = p_invoice_id;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_HAS_SETTLEMENTS|%|%', v_inv.code, v_n;
        END IF;
        -- 【SO-3b:停放的那条检查在这里落地】发货一旦释放过这张票的负债
        -- (部分或全部),冲销就没有足额的 2500 可借 —— 按名拒,更正走
        -- 【贷项凭证】(credit note,sales_records 表头停放的未来概念)。
        -- 判据是【派生】的:这张发票的行上,有没有发出去过的货。不设状态位 ——
        -- 状态位会与真相漂开,而这个问题每次都问得起(与 ship_order 的
        -- SO_SHIP_NOT_INVOICED 同一条)。
        SELECT count(*) INTO v_n
        FROM shipment_lines sl
        JOIN invoice_lines il ON il.sales_order_line_id = sl.sales_order_line_id
        WHERE il.invoice_id = p_invoice_id AND NOT il.invoice_voided;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_SHIPPED_NOT_VOIDABLE|%', v_inv.code;
        END IF;
        v_rev := reverse_journal_entry_internal(v_inv.entry_id, p_reversal_date, 'Void ' || v_inv.code);
    ELSIF v_inv.entry_id IS NOT NULL THEN
        -- ════════════════════════════════════════════════════════════════════
        -- 【GST-2:带税的 sale 型发票【有一张分录】—— 那张只过税的分录】
        -- GST-2 之前 sale 型什么都不过账,所以这一支从来不需要冲销。现在它需要:
        -- 不冲掉那张 借 1100 / 贷 2100,一张作废的发票会把销项税永远留在
        -- 2100 里,而 F5 的文档侧已经把这张票排除掉了 —— 于是勾稽的两边
        -- 会分开,而分开的原因是【作废没做完】,不是过账算错了税。
        -- 【日期必填,与 order 支逐字同一条理由】它决定冲销落进哪个期间。
        -- ════════════════════════════════════════════════════════════════════
        IF p_reversal_date IS NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
        END IF;
        -- AP-RECON-1:sale 型发票的销项税现在【可以被核销】(record_payment_internal 的
        -- 发票支)。于是这一支也要 order 支那条规矩:有活核销就不作废 —— 否则冲回了税,
        -- 收进来的那笔钱却还核销在一张已作废的发票上。先冲收款,再作废。
        SELECT count(*) INTO v_n
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.invoice_id = p_invoice_id;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_HAS_SETTLEMENTS|%|%', v_inv.code, v_n;
        END IF;
        v_rev := reverse_journal_entry_internal(v_inv.entry_id, p_reversal_date, 'Void ' || v_inv.code);
    ELSE
        -- 不带税的 sale 头没有分录可冲 —— 收下一个日期再忽略它,是在骗调用方
        -- (record_output_sale 拒 p_fx_rate 的同一条)。
        IF p_reversal_date IS NOT NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_NOT_ACCEPTED|%', v_inv.code;
        END IF;
    END IF;

    -- 明细行保留供审计;作废标记由 trg_invoices_propagate_void 同步到明细行,
    -- 行(销售或订单行)随之重新可开票。
    UPDATE invoices
    SET status = 'void',
        void_reason = btrim(p_reason),
        voided_at = now(),
        voided_by = auth.uid()
    WHERE id = p_invoice_id;

    IF v_inv.kind = 'order' THEN
        INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
        VALUES (v_inv.sales_order_id, 'invoice_voided',
                v_inv.code || ' · ' || btrim(p_reason), auth.uid());
    END IF;

    RETURN jsonb_build_object(
        'invoice_id', p_invoice_id,
        'code', v_inv.code,
        'status', 'void',
        'reversal_code', v_rev->>'code');
END;
$function$
;

-- ═══ db/functions/soft_delete_inbound_batch.sql ═══
CREATE OR REPLACE FUNCTION public.soft_delete_inbound_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_code text;
    v_open numeric;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填,而且拒绝要按名】注销一批料是一次真实的物理事件
        -- (它会写一条 writeoff 流水)。没有理由的注销,事后没有人答得出为什么。
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|inbound_batches|%',
            COALESCE((SELECT code FROM inbound_batches WHERE id = p_batch_id), '?');
    END IF;

    SELECT code INTO v_code FROM inbound_batches
     WHERE id = p_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1(Tim AP-RECON-0 Q2):【还欠着供应商钱的已计价批次,不许注销】
    --   注销只写一条 writeoff 流水(借 5200 / 贷 1200)—— 存货拿走了,那笔计价分录记下的
    --   【应付】却原样留在 2000 上。而每一个应付读者(ap_open_items、ap_aging_asof、
    --   record_payment_internal)都过滤 deleted_at IS NULL:于是那笔债从清单上消失、
    --   付款也核销不进去,只剩手工分录一条路。IN-2026-0154 的 4,032.00 就是这样来的
    --   (测试数据,不修,记在 known-wrong-until-cutover)。
    --   欠款 = 数量×单价 − 已过账付款的核销 − 预付冲抵 —— 与 ap_open_items 进料支同一条算术。
    --   【读基表,不读 ap_open_items】本函数的门是 module.inbound.edit;那张视图对没有
    --   finance.view 的读者是 0 行,读它会让一个仓库账号的"欠款为 0"成为一句假话,于是放行。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT round(round(ib.quantity * ib.unit_price, 2)
                 - COALESCE((SELECT sum(pa.allocated_ccy)
                               FROM payment_allocations pa
                               JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                              WHERE pa.inbound_batch_id = ib.id), 0)
                 - COALESCE((SELECT sum(ppa.amount_base)
                               FROM prepayment_applications ppa
                              WHERE ppa.inbound_batch_id = ib.id), 0), 2)
      INTO v_open
      FROM inbound_batches ib
     WHERE ib.id = p_batch_id AND ib.unit_price IS NOT NULL;
    IF COALESCE(v_open, 0) > 0 THEN
        RAISE EXCEPTION 'INBOUND_HAS_OPEN_PAYABLE|%|%', v_code, v_open
          USING HINT = '这批货的计价还欠着供应商这笔钱(它在应付 2000 上)—— 注销会让它从应付清单上消失、再也付不进来。先付清,或先把价格更正过来;实物损失不是注销单据的理由';
    END IF;

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE inbound_batches
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user, updated_at = now()
     WHERE id = p_batch_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);

    -- ── COD-1:注销掉的料【不是被处理掉的】────────────────────────────────
    -- 实测:线上 11 张 remaining_qty = 0 的进料批里 8 张是这一类。
    -- 一张已签发的证书在这里作废 —— 它说的是"我们处理了你的料",而这票货被报废了。
    PERFORM refresh_cod_for_batch(p_batch_id);

    RETURN jsonb_build_object('id', p_batch_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$;

-- expense_payable_ccy 是新函数:它的 EXECUTE 由 apply_migration.sh 在本事务里重放的
-- zzz_function_grants.sql 统一处理(收回 PUBLIC/anon、授 authenticated)—— 不在这里另写一份。

COMMIT;
