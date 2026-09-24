-- AP-RECON-1 Batch B(2026-09-24):清单与总账逐分相等,一笔差额要么有名字、要么就是"未解释";
-- 一件已经发生的事,日期不晚于今天。
--
-- 【Part 1 · 常设勾稽】(Tim AP-RECON-1 Q6 / Q8–Q11,Batch B Q1–Q4)
--   · 新表 list_ledger_residue:逐单据的已知残留,只有迁移能写(无写策略),重建库上为空。
--     本迁移写入线上的 7 行(应付 6、应收 1),每行带理由与 known-wrong 引用。
--   · 新函数 list_ledger_reconciliation():应付清单 ↔ 2000、应收清单 ↔ 1100,全账、不截日;
--     允许的差只有 残留 + 重估(算出来的一行)+ 挂账的收付款(算出来的一行,冲销对不算);
--     其余一律未解释,没有兜底桶。月结页有一步读它(不挡关账),明细页 /finance/list-vs-ledger。
--   · 那一分钱(APRECON1-FOREIGN-TAXED-EXPENSE-CENT,Batch B Q3):新函数 list_open_base 是
--     清单显示 open_base 的那个式子;record_payment_internal 与 create_credit_note 的解除额改成
--     "清单在这一笔之前与之后显示的差" —— 外币单据部分结清、再付清,总账每一步都恰好等于清单。
--   · 带税的订单发票(Batch B 追加裁定,与费用单同一条):一张订单发票欠的 = 净额 + 销项税。
--     order_invoice_balance_all(末尾追加三列)、ar_aging_asof、record_payment_internal(上限、
--     解除,且贷项凭证也在减欠款)、create_credit_note(税腿逐行、净额腿取余)、
--     customer_statement_data(发生 / 贷记 / 核销按总账口径)。
--   · gl_control_reconciliation:签名与键不动,只改了镜像抬头那段不成立的"实测"(不进库)。
-- 【Part 2 · 三条日期规矩】(Tim AP-RECON-1 Q7,Batch B Q5/Q5b/Q6)
--   · DOCUMENT_DATE_IN_FUTURE:费用、收付款、运费、出口运费、sale 型发票、订单发票、加工应计转费用
--     —— 日期晚于今天按名拒。
--   · POSTING_DATE_BEYOND_CURRENT_MONTH:assert_posting_allowed 拒晚于本月末的分录。
--   · REVERSAL_BEFORE_ORIGINAL:reverse_journal_entry_internal 拒早于原分录的冲销;
--     由系统代填冲销日的七次调用改走新函数 reversal_date_for(今天与原分录日里较晚的那个)。
--   · 没有测试开关:32 份把过账记进 2027–2030 的 fixture 挪到了真实的过去。
--
-- 【落地那一刻线上什么变】总账一分不动(0 张新分录)。清单 / 总账读数不变(线上 0 张带税订单发票、
-- 0 张部分结清的外币单据受影响 —— 解除只影响【以后】的核销)。新增 7 行残留;其余全是闸。
--
-- 每一个对象都从它的镜像原样取来(视图改成 CREATE OR REPLACE —— 列集只在末尾追加)。

BEGIN;

-- ═══ db/functions/list_open_base.sql ═══
-- db/functions/list_open_base.sql
-- AP-RECON-1 Batch B(2026-09-24):一张单据还开着 p_open(单据币种)时,清单上它显示的本位币。
--
-- 【它就是清单的那个式子,抽出来给【解除】那一侧用】ap_open_items / ar_open_items /
-- order_invoice_balance_all 对一张开着的单据显示的 open_base,逐支都是同一个形状:
--   · 一分都还没结 → 过账时存下的本位币(expenses 的两腿之和、freight / sales 的 amount_base、
--     订单发票净额那一腿)—— 这就是总账为它记下的数;
--   · 结了一部分 → round(剩余 × 入账汇率, 2);
--   · 结清 → 0(它离开清单)。
--
-- 【为什么解除要用它】此前一笔核销解除的本位币是 round(核销额 × 入账汇率, 2)。而清单
-- 显示的是 round(剩余 × 汇率, 2)。round(a×f) + round((G−a)×f) 与 round(G×f) 可以差一分 ——
-- 于是一张外币单据部分结清之后,清单与总账差一分;付清时 2000 / 1100 上留一分
-- (APRECON1-FOREIGN-TAXED-EXPENSE-CENT;fixture 213 B 的那组数:2.47 + 11.04 ≠ 13.50)。
-- 现在:解除额 = list_open_base(之前) − list_open_base(之后)。逐笔相减、逐笔相加,
-- 总账为这张单剩下的,【按构造】就等于清单此刻显示的那个数;付清时恰好归零。
-- 这不是第二份算术:清单与解除读的是同一个式子,这支函数就是它唯一写下来的地方。
--
-- 本位币单据(汇率 1)上三支给出的都是 p_open 本身 —— 老路径逐字节不变。
--
-- NOTE: introduced by db/migrations/2026-09-24-aprecon1b-the-list-and-the-ledger-agree.sql.
CREATE OR REPLACE FUNCTION public.list_open_base(p_open numeric, p_value numeric, p_birth_base numeric, p_fx numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN p_open <= 0 THEN 0::numeric
                WHEN p_open >= p_value THEN p_birth_base
                ELSE round(p_open * p_fx, 2) END
$function$;

-- ═══ db/functions/reversal_date_for.sql ═══
-- db/functions/reversal_date_for.sql
-- AP-RECON-1 Batch B(2026-09-24,Tim Batch B Q5):一张【由系统代填冲销日】的冲销,冲销日取
-- 今天与原分录日期里较晚的那一个。
--
-- 【为什么需要它】reverse_journal_entry_internal 从本刀起拒绝早于原分录的冲销
-- (REVERSAL_BEFORE_ORIGINAL;FRT-2027-* 的冲销记在原件之前一年,截在两者之间的 as-at
-- 报表只看得见冲销那一条腿)。而七个调用点(费用 / 付款 / 运费冲销、薪资撤回、加工分摊重做
-- 与回滚 ×2)从来不问人要日期,直接盖 CURRENT_DATE。薪资按【发薪日】过账、加工按作业日
-- 过账,两者都可以晚于今天(不晚于本月末,见 assert_posting_allowed):今天撤回一张月末
-- 发薪的薪资是正当的更正,拦下它没有道理 —— 于是冲销落在原分录那一天,而不是被拒。
-- 【由人给日期的调用点不走这里】(日记账页、作废发票、冲销代扣汇款、冲销银行转账):
-- 人给了一个早于原分录的日子,就按名拒 —— 那是一个可以改的输入,不是一个要替人改的数。
--
-- 它只是一个表达式,抽出来是为了七处写的是同一句话,而不是七份各自记得 GREATEST 的副本。
--
-- NOTE: introduced by db/migrations/2026-09-24-aprecon1b-the-list-and-the-ledger-agree.sql.
CREATE OR REPLACE FUNCTION public.reversal_date_for(p_entry_id uuid)
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT GREATEST(CURRENT_DATE, (SELECT je.entry_date FROM journal_entries je WHERE je.id = p_entry_id))
$function$;

-- ═══ db/tables/list_ledger_residue.sql ═══
-- db/tables/list_ledger_residue.sql
-- ════════════════════════════════════════════════════════════════════════════
-- AP-RECON-1 Batch B(2026-09-24):清单与总账之间【逐单据】的已知残留 —— 只有迁移能写
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【它是什么】list_ledger_reconciliation() 把每一张未结清单(应付 ↔ 2000、应收 ↔ 1100)
-- 与它的总账科目【全账、不截日】比一遍。两边之间允许的差只有三种:
--   · 本表里的行 —— 测试库上逐张单据的已知残留(Tim AP-RECON-1 Q9);
--   · 重估 —— 一条【算出来的】、有名字的行(Q10),不在本表;
--   · 挂账的收付款 —— 一条【算出来的】、有名字的行(Q6 / Batch B Q2),不在本表。
-- 其余一律是"未解释",而且没有兜底桶。
--
-- 【为什么它【只能】由迁移写】这张表的每一行都是在说"这一笔差,我们知道、我们不修"。
-- 一张界面写得进去的残留表,就是一张"让它变绿"的按钮 —— 与 document_type_exceptions
-- 同一条理由,更强:那边写错一行只是少搜一张表,这边写错一行是把一笔真差额藏起来。
--   ★ RLS 开着;写:一条策略都不给;加一行是迁移级动作,天生如此。
--   ★ 读:module.finance.view(与勾稽函数同一道门)。
--   ★ anon:不给。
--
-- 【重建出来的库上它是空的 —— 这是设计,不是遗漏】本镜像【不带】种子行。
-- 这些行描述的是测试库上切换之前的历史(docs/known-wrong-until-cutover.md 逐行有记),
-- 生产全新重建时那段历史不存在,本表也就该是空的。于是 db/fixtures/213 在重建库上
-- 要求的是【严格相等】—— 没有任何一行可以拿来解释差额。
-- 线上的 7 行由 db/migrations/2026-09-24-aprecon1b-the-list-and-the-ledger-agree.sql 写入。
--
-- 【amount_base 的符号】与勾稽函数同一个约定:它对"清单 − 总账"的贡献。
-- 正 = 清单上有、总账上没有;负 = 总账上有、清单上没有。
--
-- 行为断言:db/fixtures/213-the-list-and-the-ledger-agree-and-a-difference-has-a-name.sql

CREATE TABLE public.list_ledger_residue (
    side            text    NOT NULL CHECK (side IN ('ap', 'ar')),
    doc_code        text    NOT NULL,
    amount_base     numeric NOT NULL CHECK (amount_base <> 0),
    residue_class   text    NOT NULL CHECK (residue_class IN (
                        'priced_before_payable_posting',
                        'deleted_while_owing',
                        'fin2_backfill_units',
                        'sold_before_sales_posting')),
    -- ★ 一句话,而且【不许为空】—— 与 document_type_exceptions 同一条:
    --   一张能塞进空理由的残留表,就是一张"不要红"的名单。
    reason          text    NOT NULL,
    known_wrong_ref text    NOT NULL,
    PRIMARY KEY (side, doc_code),
    CONSTRAINT list_ledger_residue_reason_present CHECK (btrim(reason) <> ''),
    CONSTRAINT list_ledger_residue_ref_present    CHECK (btrim(known_wrong_ref) <> '')
);

COMMENT ON TABLE public.list_ledger_residue IS
    'AP-RECON-1 Batch B:清单与总账之间逐单据的已知残留(测试库的切换前历史)。只有迁移能写;重建库上为空。';

ALTER TABLE public.list_ledger_residue ENABLE ROW LEVEL SECURITY;

CREATE POLICY list_ledger_residue_select ON public.list_ledger_residue
    FOR SELECT TO authenticated USING (has_permission('module.finance.view'));

REVOKE ALL ON public.list_ledger_residue FROM anon;
GRANT SELECT ON public.list_ledger_residue TO authenticated;

-- ═══ db/views/order_invoice_balance_all.sql ═══
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


CREATE OR REPLACE VIEW public.order_invoice_balance_all WITH (security_invoker = off) AS
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

-- ═══ db/functions/list_ledger_reconciliation.sql ═══
-- db/functions/list_ledger_reconciliation.sql
-- AP-RECON-1 Batch B(2026-09-24):清单与总账的常设勾稽 —— 应付清单 ↔ 2000,应收清单 ↔ 1100。
--
-- 【它问的是一个问题,而且只问这一个】此刻清单上说欠的,与总账科目上记的,差多少;
-- 那一笔差里每一分钱有没有名字。
--   · 清单 = ap_open_items / ar_open_items 的 Σ open_base —— 应付页、应收页、付款表单
--     预填的都是它。
--   · 总账 = 控制科目【全账】余额(journal_lines,不截日、不按 status 过滤 ——
--     冲销对的两条腿都在,全时段净额为 0;FRT-2027-* 那三对因此自己抵掉)。
--
-- 【允许的差只有三种,一种也不多】(Tim AP-RECON-1 Q6 / Q8–Q10;Batch B Q1–Q2)
--   1. residue    —— list_ledger_residue 里逐单据登记的已知残留(只有迁移能写;
--                    重建库上为空)。每行带理由与 known-wrong 引用。
--   2. revaluation —— 控制科目上 source_type = 'revaluation' 的分录行,【算出来】的、
--                    有名字的一行。清单按单据入账汇率计,不重估;总账重估。两者差的
--                    就是这一行,它有自己的金额,不藏在别处。
--   3. on_account —— 挂账的收付款(没有核销到任何单据上的那部分):
--                    付款币种的 amount_ccy − Σ(allocated_pay − withheld_pay),按付款汇率
--                    折本位币 —— 与 record_payment_internal 过 v_unalloc_base 的式子同式。
--                    ★ 冲销对【两边都不算】:被冲销的原件(status = 'reversed')与冲销件
--                    (被别人的 reversed_by_payment 指着)都不是挂账的钱。不排除的话,
--                    冲销件没有核销行,会整笔读成挂账 —— 线上实测会凭空多出 4,866.08。
-- 其余一律进 unexplained_base。**没有兜底桶** —— gl_control_reconciliation 抬头那一段
-- 说的是同一件事:一个永远为 0 的判词是装饰,不是检查。
--
-- 【符号约定】每一个具名项的金额都是它对"清单 − 总账"(gap_base)的贡献:
--   unexplained_base = gap_base − residue_base − revaluation_base − on_account_base。
--   总账侧统一成"正数 = 还欠着的钱"(AR = 借 − 贷,AP = 贷 − 借)。
--
-- 【与 gl_control_reconciliation 的分工】那一支按【机制】分类(起单/结算/重估)、截在
-- as-of 日,冻在管理包里的包读它的三个键 —— 它的签名与键不动(Q8),它的抬头已改正:
-- 它的"起单差异"会把缺陷一起吸进去(AP-RECON-1 §3)。本函数按【已知残留】分类,
-- 不截日,不吸任何东西。
--
-- 【两道门】module.finance.view(require_permission);清单的金额还要 data.view_prices ——
-- 进料批、销售记录与发票的价格列都是遮蔽的,没有这个码的人读到的清单是残缺的,
-- 拿它去减总账会得到一个自信的假"未解释"。所以此时两边都【按名拒】:
-- refusal = 'PRICES_RESTRICTED',数字为 NULL —— 答不上来不是对不上。
--
-- 月结页(/finance/month-end)有一步读它,每一边一个未解释数;它【不】挡 close_period
-- (Q11:挡不挡关账是以后的决定)。明细页:/finance/list-vs-ledger。
-- 行为断言:db/fixtures/213-the-list-and-the-ledger-agree-and-a-difference-has-a-name.sql
--
-- NOTE: introduced by db/migrations/2026-09-24-aprecon1b-the-list-and-the-ledger-agree.sql.
CREATE OR REPLACE FUNCTION public.list_ledger_reconciliation()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_sides     jsonb := '[]'::jsonb;
    v_side      text;
    v_acct      text;
    v_list      numeric;
    v_rows      integer;
    v_ledger    numeric;
    v_reval     numeric;
    v_onacc     numeric;
    v_onacc_rows jsonb;
    v_res       numeric;
    v_res_rows  jsonb;
    v_gap       numeric;
    v_unexp     numeric;
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】
    PERFORM require_permission('module.finance.view');

    FOREACH v_side IN ARRAY ARRAY['ap', 'ar'] LOOP
        v_acct := CASE WHEN v_side = 'ap' THEN '2000' ELSE '1100' END;

        IF NOT has_permission('data.view_prices') THEN
            v_sides := v_sides || jsonb_build_object(
                'side', v_side, 'control_account', v_acct,
                'refusal', 'PRICES_RESTRICTED',
                'list_base', NULL, 'list_rows', NULL, 'ledger_base', NULL, 'gap_base', NULL,
                'residue', '[]'::jsonb, 'residue_base', NULL,
                'revaluation_base', NULL, 'on_account', '[]'::jsonb, 'on_account_base', NULL,
                'unexplained_base', NULL, 'agrees', NULL);
            CONTINUE;
        END IF;

        -- ── 清单 ──────────────────────────────────────────────────────────
        IF v_side = 'ap' THEN
            SELECT count(*), COALESCE(sum(open_base), 0) INTO v_rows, v_list FROM ap_open_items;
        ELSE
            SELECT count(*), COALESCE(sum(open_base), 0) INTO v_rows, v_list FROM ar_open_items;
        END IF;

        -- ── 总账:全账,不截日,不按 status 过滤 ─────────────────────────────
        SELECT COALESCE(sum(CASE WHEN v_side = 'ar' THEN jl.debit - jl.credit
                                 ELSE jl.credit - jl.debit END), 0)
          INTO v_ledger
          FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
         WHERE a.code = v_acct;

        -- ── 具名项 2:重估(总账侧的数;它对 gap 的贡献是它的相反数)─────────
        SELECT COALESCE(sum(CASE WHEN v_side = 'ar' THEN jl.debit - jl.credit
                                 ELSE jl.credit - jl.debit END), 0)
          INTO v_reval
          FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
          JOIN journal_entries je ON je.id = jl.entry_id
         WHERE a.code = v_acct AND je.source_type = 'revaluation';

        -- ── 具名项 3:挂账的收付款,冲销对两边都不算 ─────────────────────────
        SELECT COALESCE(sum(u.base), 0),
               COALESCE(jsonb_agg(jsonb_build_object('code', u.code, 'amount_base', u.base)
                                  ORDER BY u.code), '[]'::jsonb)
          INTO v_onacc, v_onacc_rows
          FROM (SELECT p.code,
                       round(round(p.amount_ccy - COALESCE(
                           (SELECT sum(pa.allocated_pay - pa.withheld_pay)
                              FROM payment_allocations pa
                             WHERE pa.payment_id = p.id), 0), 2) * p.fx_rate, 2) AS base
                  FROM payments p
                 WHERE p.direction = CASE WHEN v_side = 'ap' THEN 'out' ELSE 'in' END
                   AND p.status = 'posted'
                   AND NOT EXISTS (SELECT 1 FROM payments o WHERE o.reversed_by_payment = p.id)) u
         WHERE u.base <> 0;

        -- ── 具名项 1:登记的残留 ────────────────────────────────────────────
        SELECT COALESCE(sum(r.amount_base), 0),
               COALESCE(jsonb_agg(jsonb_build_object(
                   'doc_code', r.doc_code, 'amount_base', r.amount_base,
                   'residue_class', r.residue_class, 'reason', r.reason,
                   'known_wrong_ref', r.known_wrong_ref) ORDER BY r.doc_code), '[]'::jsonb)
          INTO v_res, v_res_rows
          FROM list_ledger_residue r
         WHERE r.side = v_side;

        v_gap   := round(v_list - v_ledger, 2);
        -- ★【没有兜底桶】★ 只扣这三项。
        v_unexp := round(v_gap - v_res - (-v_reval) - v_onacc, 2);

        v_sides := v_sides || jsonb_build_object(
            'side',             v_side,
            'control_account',  v_acct,
            'refusal',          NULL,
            'list_base',        round(v_list, 2),
            'list_rows',        v_rows,
            'ledger_base',      round(v_ledger, 2),
            'gap_base',         v_gap,
            'residue',          v_res_rows,
            'residue_base',     round(v_res, 2),
            'revaluation_base', round(-v_reval, 2),
            'on_account',       v_onacc_rows,
            'on_account_base',  round(v_onacc, 2),
            'unexplained_base', v_unexp,
            'agrees',           (v_unexp = 0));
    END LOOP;

    RETURN jsonb_build_object(
        'base_currency', base_currency_code(),
        'sides',         v_sides);
END;
$function$
;

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
    v_birth        numeric;   -- AP-RECON-1 Batch B:这张单过账时记下的本位币(清单未结时显示的就是它)
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
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):收付款是一件【已经发生】的事 —— 此前没有任何上界,日期晚于今天按名拒。
    IF v_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|payment|%|%', v_date, CURRENT_DATE;
    END IF;
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
                       -- AP-RECON-1 Batch B:订单发票欠的 = 净额 + 销项税(order_invoice_balance_all,
                       -- 清单、账龄、敞口、贷项凭证天花板读的同一处)。此前只认 Σ 明细行,
                       -- 一张带税的订单发票那笔税永远收不进来。
                       CASE WHEN i.kind = 'order' THEN b.amount_ccy
                            ELSE i.tax_base END AS doc_value,
                       CASE WHEN i.kind = 'order' THEN i.currency ELSE v_base END AS doc_ccy,
                       CASE WHEN i.kind = 'order' THEN i.fx_rate ELSE 1::numeric END AS doc_fx,
                       -- AP-RECON-1 Batch B:过账时 1100 上为它记下的本位币 —— 订单发票是净额腿
                       -- round(Σ行 × 汇率) + 税那条腿 tax_base;sale 型发票的那一笔就是 tax_base。
                       CASE WHEN i.kind = 'order' THEN b.birth_base
                            ELSE i.tax_base END AS birth_base,
                       i.kind AS inv_kind, b.credited_ccy AS credited_ccy
                INTO v_doc
                FROM invoices i
                LEFT JOIN order_invoice_balance_all b ON b.invoice_id = i.id
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
                v_birth := v_doc.birth_base;
                v_key := v_invoice_id::text;

                SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.invoice_id = v_invoice_id;
                -- AP-RECON-1 Batch B:贷项凭证也在减这张订单发票的欠款 —— order_invoice_balance_all
                -- (清单、账龄、敞口读的那一处)一直是 金额 − 已收 − 已贷记。只有这里漏了它:
                -- 开过贷项凭证之后,收款上限仍按没贷记之前算,解除额也就对不上清单。
                IF v_doc.inv_kind = 'order' THEN
                    v_settled := v_settled + COALESCE(v_doc.credited_ccy, 0);
                END IF;
            ELSE
                SELECT sr.id, ob.code AS doc_code, sr.customer_id AS party_id,
                       round(sr.quantity * sr.unit_price, 2) AS doc_value,
                       sr.currency AS doc_ccy, sr.fx_rate AS doc_fx,
                       sr.amount_base AS birth_base
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
                v_birth := v_doc.birth_base;
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
            v_birth := v_doc_value;
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
                   fd.amount_ccy AS doc_value, fd.currency AS doc_ccy, fd.fx_rate AS doc_fx,
                   fd.amount_base AS birth_base
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
            v_birth := v_doc.birth_base;
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
                   e.wht_rate_pct AS wht_rate_pct,
                   e.amount_base + COALESCE(e.tax_base, 0) AS birth_base
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
            v_birth := v_doc.birth_base;
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
        -- ════════════════════════════════════════════════════════════════════
        -- AP-RECON-1 Batch B:解除的本位币 = 清单在这一笔【之前】与【之后】显示的差。
        -- 此前是 round(核销额 × 入账汇率):外币单据部分结清之后,清单(round(剩余 × 汇率))
        -- 与总账差一分,付清时控制科目上留一分(APRECON1-FOREIGN-TAXED-EXPENSE-CENT)。
        -- list_open_base 就是清单的那个式子;逐笔相减,总账为这张单剩下的按构造等于清单。
        -- 本位币单据(汇率 1)两式相同,老路径逐字节不变。预付(v_doc_value 为 NULL)不是
        -- 在解除一笔应付,照旧按付款口径入 1300,见下。
        -- ════════════════════════════════════════════════════════════════════
        IF v_doc_value IS NULL THEN
            v_alloc_base := round(v_alloc_usd * v_doc_fx, 2);
        ELSE
            v_open := round(v_doc_value - v_settled - COALESCE((v_running->>v_key)::numeric, 0), 2);
            v_alloc_base := list_open_base(v_open, v_doc_value, v_birth, v_doc_fx)
                          - list_open_base(round(v_open - v_alloc_usd, 2), v_doc_value, v_birth, v_doc_fx);
        END IF;
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

-- ═══ db/functions/create_credit_note.sql ═══
CREATE OR REPLACE FUNCTION public.create_credit_note(p_invoice_id uuid, p_note_date date, p_reason text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_inv      invoices%ROWTYPE;
    v_cn_id    uuid := gen_random_uuid();
    v_code     text;
    v_open     numeric;
    v_amt      numeric;   -- AP-RECON-1 Batch B:发票净额(单据币种),清单的分母
    v_relief   numeric;   -- AP-RECON-1 Batch B:1100 净额腿解除的本位币
    v_a_base   numeric;
    v_birth    numeric;   -- AP-RECON-1 Batch B:这张发票过账时 1100 上的本位币(净额腿 + 税腿)
    v_el       jsonb;
    v_line_id  uuid;
    v_kind     text;
    v_amount   numeric;
    v_total    numeric := 0;
    v_a_total  numeric := 0;
    v_b_total  numeric := 0;
    v_grp      record;
    v_shipped  numeric;
    v_released numeric;
    v_ceiling  numeric;
    v_prior    numeric;
    v_je       jsonb;
    v_jlines   jsonb;
    v_n        int;
    -- ── GST-2 ────────────────────────────────────────────────────────────
    v_tax_total numeric := 0;   -- 本凭证退回的销项税,单据币种
    v_tax_base_total numeric := 0;   -- 同上,本位币 —— 逐行取整再相加(= F5 读的那个数)
    v_ln_code  text;            -- 被冲那一行【冻住的】税码
    v_ln_rate  numeric;         -- 同上,冻住的税率
    v_ln_tax   numeric;
BEGIN
    -- 【为什么是 module.finance.edit】它直接改总账与应收 —— 与
    -- create_order_invoice(开票)同一道门。开票认下债,这张把债减回去。
    PERFORM require_permission('module.finance.edit');

    -- 【单据日必填,永不默认】它决定冲销落进哪个期间。补一个 CURRENT_DATE
    -- 会让留空比填对更容易通过:今天的日期永远撞不上 PERIOD_LOCKED。
    IF p_note_date IS NULL THEN
        RAISE EXCEPTION 'CN_NOTE_DATE_REQUIRED';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CN_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    -- 【这两条守卫【也】在触发器上】这里再问一遍,是为了在算任何天花板之前
    -- 就给出正确的名字 —— 触发器要到 INSERT 那一刻才说话,而那时人已经
    -- 填完整张表单了(CMP-2:禁用与说明要在动作之前)。
    IF v_inv.kind <> 'order' THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_ORDER_KIND|%|%', v_inv.code, v_inv.kind;
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'CN_INVOICE_VOID|%', v_inv.code;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'CN_NO_LINES|%', v_inv.code;
    END IF;

    -- ── 天花板 ①:整张凭证 ≤ 这张发票【当下的】开放余额 ─────────────────────
    -- 读的是那一处不带过滤的算术(order_invoice_balance_all)。带过滤的那张
    -- 在 open = 0 时【没有行】,而把"没有行"读成 0 正是本仓库反复修的毛病 ——
    -- 这里要的恰恰是那个 0,并且要为它给出一个【专门的名字】。
    SELECT open_ccy, amount_ccy, birth_base INTO v_open, v_amt, v_birth FROM order_invoice_balance_all WHERE invoice_id = p_invoice_id;
    IF v_open IS NULL THEN
        -- issued + order 型必有一行(上面两条已经排除了别的情形)。走到这里
        -- 说明视图的前提变了 —— 当场炸,不要把它当成 0(那会让天花板消失)。
        RAISE EXCEPTION 'CN_BALANCE_MISSING|%', v_inv.code;
    END IF;
    IF v_open <= 0 THEN
        -- 【已经结清的发票不能再贷记】要还的是【现金】,那是一张付款单加一个
        -- 客户贷余概念,而这个系统今天没有客户贷余的落脚点。按名拒,
        -- 而不是让应收变成负数(那会在账龄上凭空消失、在敞口里悄悄抵扣)。
        RAISE EXCEPTION 'CN_INVOICE_FULLY_SETTLED|%', v_inv.code;
    END IF;

    -- ── 逐行校验 ────────────────────────────────────────────────────────────
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_line_id := NULLIF(v_el->>'invoice_line_id', '')::uuid;
        v_kind    := v_el->>'kind';
        v_amount  := NULLIF(v_el->>'amount', '')::numeric;

        IF v_line_id IS NULL THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'invoice_line_id';
        END IF;
        IF v_kind IS NULL OR v_kind NOT IN ('unshipped_cancel','revenue_reduction') THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'kind';
        END IF;
        IF v_amount IS NULL OR v_amount <= 0 THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'amount';
        END IF;
        SELECT tax_code, tax_rate_pct INTO v_ln_code, v_ln_rate
          FROM invoice_lines WHERE id = v_line_id AND invoice_id = p_invoice_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CN_LINE_WRONG_INVOICE|%', v_line_id;
        END IF;

        -- 【GST-2:税码与税率【从被冲的那一行抄来】,不重新解析】
        -- 冲的是哪一笔供应,就退哪一笔供应的税 —— 连它当时那个税率一起,
        -- 即便法定税率此后变过。按 note_date 重新解析会用今天的税率去退
        -- 一笔按去年税率收过的税,差额无声地留在 2100 里。
        v_ln_tax := CASE WHEN v_ln_code IS NULL THEN 0
                         ELSE round(v_amount * v_ln_rate / 100.0, 2) END;
        v_tax_total := v_tax_total + v_ln_tax;
        -- 【本位币侧逐行取整再相加】F5 的 box6 读的就是 credit_note_lines.tax_base,
        -- 而那一列存的正是这个逐行 round 的值 —— 两处必须同式,否则勾稽会误报。
        v_tax_base_total := v_tax_base_total + round(v_ln_tax * v_inv.fx_rate, 2);

        v_total := v_total + v_amount;
        IF v_kind = 'unshipped_cancel' THEN v_a_total := v_a_total + v_amount;
        ELSE                                v_b_total := v_b_total + v_amount; END IF;
    END LOOP;

    -- 【与开放余额比的是【含税】总额】开票额从 GST-2 起是净额 + 销项税,
    -- 而这张凭证退的也是净额 + 税。只拿净额去比,天花板会松掉一截税。
    IF round(v_total + v_tax_total, 2) > round(v_open, 2) THEN
        RAISE EXCEPTION 'CN_EXCEEDS_OPEN|%|%', round(v_total + v_tax_total, 2), round(v_open, 2);
    END IF;

    -- ── 天花板 ② / ③:逐【发票行 × 类型】────────────────────────────────────
    -- 【按分组算,不是逐条算】一张凭证可以在同一发票行上放两条同类型的行,
    -- 逐条检查会让两条各自"没超"、合起来超掉。分组之后再与【历史】相加。
    FOR v_grp IN
        SELECT (e->>'invoice_line_id')::uuid AS line_id,
               e->>'kind' AS kind,
               sum((e->>'amount')::numeric) AS want
        FROM jsonb_array_elements(p_lines) e
        GROUP BY 1, 2
    LOOP
        -- 这一行【已发】多少 —— 读 shipment_lines(货真的离开台账的记录,
        -- 与 line_spoken_for 同一个理由)。
        -- 【为什么可以拿发票行的单价去乘】SO-1b 起,坐在在册发票上的订单行
        -- 数量与单价【整个冻住】(SO_AMEND_LINE_INVOICED),所以发票行的单价
        -- 与发货当时用的那个是同一个数。这一条是本段算术的前提,不是巧合。
        SELECT COALESCE(sum(sl.qty), 0) INTO v_shipped
          FROM shipment_lines sl
          JOIN invoice_lines il ON il.sales_order_line_id = sl.sales_order_line_id
         WHERE il.id = v_grp.line_id;
        SELECT round(v_shipped * il.unit_price, 2) INTO v_released
          FROM invoice_lines il WHERE il.id = v_grp.line_id;

        -- 这一行同类型的【历史】贷记额
        SELECT COALESCE(sum(cl.amount), 0) INTO v_prior
          FROM credit_note_lines cl
         WHERE cl.invoice_line_id = v_grp.line_id AND cl.kind = v_grp.kind;

        IF v_grp.kind = 'unshipped_cancel' THEN
            -- 未释放的负债 = 这一行开票额 − 已释放进收入的部分
            SELECT round(il.amount_ccy - v_released, 2) INTO v_ceiling
              FROM invoice_lines il WHERE il.id = v_grp.line_id;
            v_ceiling := round(v_ceiling - v_prior, 2);
            IF round(v_grp.want, 2) > v_ceiling THEN
                RAISE EXCEPTION 'CN_EXCEEDS_UNRELEASED|%|%|%',
                    (SELECT line_no FROM invoice_lines WHERE id = v_grp.line_id),
                    round(v_grp.want, 2), v_ceiling;
            END IF;
        ELSE
            v_ceiling := round(v_released - v_prior, 2);
            IF round(v_grp.want, 2) > v_ceiling THEN
                RAISE EXCEPTION 'CN_EXCEEDS_RELEASED|%|%|%',
                    (SELECT line_no FROM invoice_lines WHERE id = v_grp.line_id),
                    round(v_grp.want, 2), v_ceiling;
            END IF;
        END IF;
    END LOOP;

    -- ── 过账:一张分录 ──────────────────────────────────────────────────────
    -- 【借 2500 未释放的那部分 / 借 4000 已释放的那部分 / 贷 1100 合计】
    -- 单据币种,按【发票存下来的】汇率 —— 见迁移抬头:换个汇率会凭空造出
    -- 一笔看起来完全正常的已实现汇兑,而没有任何钱动过。
    -- 【0 金额的腿一条都不发】post_journal_entry 的 amount_ccy > 0 会拒,
    -- 而且一条 0 的腿在分录上读起来像"这一段发生了但金额为零"。
    v_code := next_credit_note_code(p_note_date);
    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1 Batch B:1100 解除的本位币 = 清单在这张凭证【之前】与【之后】
    -- 显示的差(list_open_base,与 record_payment_internal 的解除同一个式子);
    -- 税那条腿按它自己逐行取整的数,净额腿(v_relief)取其余。
    -- 此前是 round(合计 × 汇率):外币发票部分收过款之后再贷记,清单(round(剩余 × 汇率))
    -- 与总账差一分(fixture 213 C9)。借方跟着它走:有两条借方腿时,已释放那条
    -- (4000)取 解除额 − 未释放那条,于是分录按构造平衡;本位币(汇率 1)逐字节不变。
    -- 腿的 fx 写成 目标基准额 ÷ 原币额 —— 除后反乘取整恰好还原(record_payment 同一手)。
    -- ════════════════════════════════════════════════════════════════════════
    -- 带税时这张凭证解除的是 净额 + 税;税那条腿照旧逐行取整(F5 读它),净额腿取余下的。
    v_relief := list_open_base(v_open, v_amt, v_birth, v_inv.fx_rate)
              - list_open_base(round(v_open - v_total - v_tax_total, 2), v_amt, v_birth, v_inv.fx_rate)
              - round(v_tax_base_total, 2);
    v_a_base := CASE WHEN v_b_total > 0 THEN round(round(v_a_total, 2) * v_inv.fx_rate, 2) ELSE v_relief END;
    v_jlines := '[]'::jsonb;
    IF v_a_total > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '2500', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_a_total, 2),
            'fx_rate', v_a_base / round(v_a_total, 2),
            'line_memo', 'unshipped cancelled');
    END IF;
    IF v_b_total > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '4000', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_b_total, 2),
            'fx_rate', (v_relief - CASE WHEN v_a_total > 0 THEN v_a_base ELSE 0 END) / round(v_b_total, 2),
            'line_memo', 'revenue reduction');
    END IF;
    -- 【GST-2:退回去的税借 2100】—— 一张贷项凭证在 F5 上是一笔【负的供应】,
    -- 它的税也要从销项税里减回去。1100 那条腿因此贷【含税】总额:
    -- 客户少欠的钱就是净额 + 那笔税。
    IF round(v_tax_total, 2) > 0 THEN
        -- 【fx 用 v_tax_base_total / v_tax_total —— 与 create_order_invoice 同一手】
        -- 逐行取整的合计与 round(合计 × 汇率) 在外币下可以差一分,而 F5 读的是
        -- 前者、总账记的是后者 —— 差那一分,勾稽就会在一张正确的凭证上报 false。
        v_jlines := v_jlines || jsonb_build_object('account_code', '2100', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_tax_total, 2),
            'fx_rate', round(v_tax_base_total, 2) / round(v_tax_total, 2),
            'line_memo', 'output tax reversed');
    END IF;
    -- 【净额与税分成两条贷方腿】逐行 round(原币 × 汇率) 之下,一条合并腿会与
    -- 借方两条差一分钱 —— 与 record_expense / create_order_invoice 同一条理由。
    v_jlines := v_jlines || jsonb_build_object('account_code', '1100', 'side', 'credit',
        'currency', v_inv.currency, 'amount_ccy', round(v_total, 2), 'fx_rate', v_relief / round(v_total, 2));
    IF round(v_tax_total, 2) > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '1100', 'side', 'credit',
            'currency', v_inv.currency, 'amount_ccy', round(v_tax_total, 2),
            'fx_rate', round(v_tax_base_total, 2) / round(v_tax_total, 2),
            'line_memo', 'GST on ' || v_code);
    END IF;

    v_je := post_journal_entry(
        p_note_date,
        'Credit note ' || v_code || ' · ' || v_inv.code,
        'credit_note', v_cn_id,
        v_jlines);

    -- 【先过账再写单头】entry_id 因此可以是 NOT NULL,不需要"先写空、再回填"
    -- 那种单向放宽(与 create_order_invoice 逐字同一个顺序)。
    INSERT INTO credit_notes (id, code, invoice_id, reason, note_date, entry_id,
                              currency, fx_rate, created_by)
    VALUES (v_cn_id, v_code, p_invoice_id, btrim(p_reason), p_note_date,
            (v_je->>'entry_id')::uuid, v_inv.currency, v_inv.fx_rate, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        SELECT tax_code, tax_rate_pct INTO v_ln_code, v_ln_rate
          FROM invoice_lines WHERE id = (v_el->>'invoice_line_id')::uuid;
        INSERT INTO credit_note_lines (credit_note_id, invoice_line_id, kind, qty, amount,
                                       tax_code, tax_rate_pct, tax_base)
        VALUES (v_cn_id,
                (v_el->>'invoice_line_id')::uuid,
                v_el->>'kind',
                NULLIF(v_el->>'qty', '')::numeric,
                (v_el->>'amount')::numeric,
                v_ln_code,
                v_ln_rate,
                CASE WHEN v_ln_code IS NULL THEN 0
                     ELSE round(round((v_el->>'amount')::numeric * v_ln_rate / 100.0, 2)
                                * v_inv.fx_rate, 2) END);
    END LOOP;

    -- 【断言,不是假设】行的条数必须等于递进来的条数。将来有人给上面那个循环
    -- 加一个提前 CONTINUE,这里当场炸,而不是留下一张【分录按全部行算过、
    -- 明细却少了几条】的凭证 —— 那种凭证的总额与它自己的行对不上。
    SELECT count(*) INTO v_n FROM credit_note_lines WHERE credit_note_id = v_cn_id;
    IF v_n <> jsonb_array_length(p_lines) THEN
        RAISE EXCEPTION 'CN_LINES_LOST|%|%', jsonb_array_length(p_lines), v_n;
    END IF;

    -- 【订单历史也记一笔】看订单的人问"这张单后来减过账没有",那个问题的答案
    -- 不该要求他先去翻发票列表(与 'invoiced' / 'invoice_voided' 同一条)。
    IF v_inv.sales_order_id IS NOT NULL THEN
        INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
        VALUES (v_inv.sales_order_id, 'credit_noted',
                v_code || ' · ' || v_inv.currency || ' ' || trim_scale(round(v_total, 2))::text
                || ' · ' || btrim(p_reason), v_user);
    END IF;

    RETURN jsonb_build_object(
        'credit_note_id', v_cn_id,
        'code', v_code,
        'invoice_code', v_inv.code,
        'note_date', p_note_date,
        'currency', v_inv.currency,
        'fx_rate', v_inv.fx_rate,
        'total_ccy', round(v_total, 2),
        'total_base', round(round(v_total, 2) * v_inv.fx_rate, 2),
        'unshipped_cancel_ccy', round(v_a_total, 2),
        'revenue_reduction_ccy', round(v_b_total, 2),
        'line_count', v_n,
        'open_ccy_after', round(v_open - v_total, 2),
        'journal_code', v_je->>'code');
END;
$function$
;

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
        -- AP-RECON-1 Batch B:金额 = 净额 + 销项税、已贷记含税、open_base 走 list_open_base
        -- (未结时 = 过账的两条腿之和)—— 与 order_invoice_balance_all 同一刀改。
        SELECT NULL::uuid, i.code, i.customer_id, c.legal_name,
               i.issue_date, i.due_date,
               round((l.amount_ccy + l.tax_ccy) * i.fx_rate, 2),
               i.currency, round(l.amount_ccy + l.tax_ccy, 2),
               round(COALESCE(s.settled, 0), 2),
               round(l.amount_ccy + l.tax_ccy - COALESCE(s.settled, 0) - COALESCE(cn.credited, 0), 2),
               list_open_base(round(l.amount_ccy + l.tax_ccy - COALESCE(s.settled, 0) - COALESCE(cn.credited, 0), 2),
                              round(l.amount_ccy + l.tax_ccy, 2),
                              round(l.amount_ccy * i.fx_rate, 2) + COALESCE(i.tax_base, 0), i.fx_rate),
               (v_as_of - i.issue_date),
               aging_bucket(v_as_of - i.issue_date),
               i.id, i.code, 'invoice'::text,
               round(COALESCE(s.settled, 0) * i.fx_rate, 2),
               round(COALESCE(cn.credited, 0), 2),
               round(COALESCE(cn.credited, 0) * i.fx_rate, 2)
          FROM invoices i
          LEFT JOIN customers c ON c.id = i.customer_id
          JOIN LATERAL (
                SELECT COALESCE(sum(il.amount_ccy), 0) AS amount_ccy,
                       COALESCE(sum(CASE WHEN il.tax_code IS NULL THEN 0
                                         ELSE tax_amount_for(il.amount_ccy, il.tax_rate_pct) END), 0) AS tax_ccy
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
                SELECT sum(cl.amount + CASE WHEN cl.tax_code IS NULL THEN 0
                                            ELSE tax_amount_for(cl.amount, cl.tax_rate_pct) END) AS credited
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
    -- AP-RECON-1 Batch B:取 allocated_base —— 它现在【就是】这一笔让清单少显示的本位币
    -- (record_payment_internal 按 list_open_base 前后之差解除)。此前在这里重乘
    -- allocated_ccy × 入账汇率:外币单据部分结清时,与账龄那一侧的期末差一分,对账单不寄。
    -- (sale 型发票的税:allocated_base 本来就是本位币,那个"乘 NULL"的坑随之消失。)
    SELECT COALESCE(round(sum(pa.allocated_base), 2), 0)
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
    -- AP-RECON-1 Batch B:一张贷项凭证减掉的应收 = 它的分录贷 1100 的那两条腿(净额 + 税),
    -- 按总账读 —— create_credit_note 按清单前后之差解除,所以这就是账龄那一侧少掉的数。
    -- 此前是 Σ 行净额 × 汇率:带税的凭证漏掉税,外币部分结清后再贷记差一分。
    SELECT COALESCE(round(sum((SELECT COALESCE(sum(jl.credit - jl.debit), 0)
                                 FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
                                WHERE jl.entry_id = cn.entry_id AND a.code = '1100')), 2), 0)
      INTO v_credits
      FROM credit_notes cn
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
             -- AP-RECON-1 Batch B:订单发票的发生 = 过账时借 1100 的两条腿(净额 + 税)。
             (SELECT COALESCE(sum(round(l.amount_ccy * i.fx_rate, 2) + COALESCE(i.tax_base, 0)), 0)
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

-- ═══ db/functions/assert_posting_allowed.sql ═══
CREATE OR REPLACE FUNCTION public.assert_posting_allowed(p_entry_date date, p_source_type text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locked      date;
    v_year_closed date;
BEGIN
    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):【分录日期不得晚于本月最后一天】
    --   此前这里只有下界(年结、月锁),没有上界 —— LOG-4b 的测试单就是这样把
    --   JE-2027-0001…0003 记进了真账(一年后的日子,还占掉了 2027 年的无缝编号)。
    --   【为什么是月末而不是今天】折旧、重估、薪资按【期末日】过账,月结可以在 28 号做;
    --   以今天为界会把正当的月结拦在门外。业务单据(运费、费用、发票、收付款)在各自的
    --   函数里另有一道更紧的闸:日期晚于今天按名拒 —— 那是"一件已经发生的事"的判据,
    --   这里是"账不许记进下个月"的判据,两者不是同一个问题。
    --   【没有测试开关】fixture 把日期挪到真实的过去,而不是在这道闸上开一个口子(Tim Q7)。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_entry_date > (date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date THEN
        RAISE EXCEPTION 'POSTING_DATE_BEYOND_CURRENT_MONTH|%|%', p_entry_date,
            (date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date;
    END IF;

    -- 【FIN-23:已结年度守卫 —— 与月锁无关的第二道闸,排在月锁之前】
    -- locked_before 是一条会动的线:reopen_period(月级、合法、留痕)会把它退回
    -- 已结年度之内 —— 回填分录进去,损益科目再动,留存收益就悄悄错了。这道闸
    -- 不跟着锁退:日期落进【仍有效】年结(year_closes.reopened_at IS NULL)的
    -- 一律点名拒绝。两道都命中时报 YEAR_CLOSED —— 年是更强的事实。
    -- 年结自己的分录凭 evoltrya.close_ctx 过(close_financial_year /
    -- reopen_financial_year 在同一事务内设置,用毕即清 —— movement_ctx 同款);
    -- 结转分录在 year_closes 行落库之前过账,本闸对它本就无感,ctx 是给
    -- 重开的冲销分录用的(先过账、后一次性盖章)。
    IF NOT (p_source_type = 'year_close'
            AND current_setting('evoltrya.close_ctx', true) = 'year_close') THEN
        SELECT MAX(yc.year_end) INTO v_year_closed
        FROM year_closes yc
        WHERE yc.reopened_at IS NULL AND p_entry_date <= yc.year_end;
        IF v_year_closed IS NOT NULL THEN
            RAISE EXCEPTION 'YEAR_CLOSED|%|%', p_entry_date, v_year_closed;
        END IF;
    END IF;

    -- 期间锁:早于 locked_before 的日期拒绝。
    -- 例外(FIN-23):年结分录及其冲销必须写进已被月结锁住的年末 ——
    -- 仅当 source_type='year_close' 且 close_ctx 在场时放行,别无他路。
    SELECT locked_before INTO v_locked FROM finance_settings WHERE id;
    IF v_locked IS NOT NULL AND p_entry_date < v_locked
       AND NOT (p_source_type = 'year_close'
                AND current_setting('evoltrya.close_ctx', true) = 'year_close') THEN
        RAISE EXCEPTION 'PERIOD_LOCKED|%|%', p_entry_date, v_locked;
    END IF;
END;
$function$;

-- ═══ db/functions/reverse_journal_entry_internal.sql ═══
-- db/functions/reverse_journal_entry_internal.sql
-- 冲销分录的【内部算子】:DEFINER,不检查权限,EXECUTE 已对 PUBLIC/authenticated/anon 收回。
--
-- 为什么要拆:reverse_journal_entry 既是财务的界面入口(必须查 module.finance.edit),
-- 又是别的动作的内部一步 —— 运营重做成本分摊要先冲掉上一次的资本化分录,
-- 人力资源反过账要冲掉薪资分录。DEFINER 不改变 auth.uid(),所以内层检查查的仍是
-- 最终用户,于是这两个岗位会被财务的码挡在自己的正当动作外面。
--
-- 手工冲销一张分录仍然要 module.finance.edit;变的只是:检查的是【正在做的那件事】
-- 的权限,而不是这件事在账上留下的痕迹所属模块的权限(cut 2a B4(b) 的规矩)。
--
-- NOTE: introduced by db/migrations/2026-08-02-perm3b-reversal-boundary.sql.
CREATE OR REPLACE FUNCTION public.reverse_journal_entry_internal(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        record;
    v_lines       jsonb;
    v_result      jsonb;
    v_reversal_id uuid;
BEGIN
    SELECT * INTO v_orig FROM journal_entries WHERE id = p_entry_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JE_NOT_FOUND|%', p_entry_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by IS NOT NULL THEN
        RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_orig.code;
    END IF;
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):【冲销不许早于原分录】FRT-2027-0001…0003 的冲销
    -- 按 CURRENT_DATE 记在 2026-08-20,原件却在 2027-09-05 —— 任何截在两者之间的 as-at 报表
    -- 只看得见冲销那一条腿(gl_control_reconciliation 因此少算 3,703.68)。
    -- 由系统代填冲销日的七个调用点走 reversal_date_for(今天与原分录日里较晚的那个);
    -- 由人给日期的调用点,给了一个早于原分录的日子就在这里按名拒。
    IF p_reversal_date < v_orig.entry_date THEN
        RAISE EXCEPTION 'REVERSAL_BEFORE_ORIGINAL|%|%|%', v_orig.code, p_reversal_date, v_orig.entry_date;
    END IF;

    -- 行全部翻边(debit↔credit),原币金额/汇率原样 → USD 侧必然精确对冲。
    -- 【GST-2:tax_code 一起翻过去】不抄它,一笔冲销掉的采购会永远留在 box5。
    SELECT jsonb_agg(
        jsonb_build_object(
            'account_code', a.code,
            'side', CASE WHEN l.debit > 0 THEN 'credit' ELSE 'debit' END,
            'currency', l.currency,
            'amount_ccy', l.amount_ccy,
            'fx_rate', l.fx_rate,
            'line_memo', l.line_memo,
            'tax_code', l.tax_code
        ) ORDER BY l.created_at, l.id
    ) INTO v_lines
    FROM journal_lines l
    JOIN accounts a ON a.id = l.account_id
    WHERE l.entry_id = p_entry_id;

    -- 期间锁由 post_journal_entry 对 p_reversal_date 统一执行
    v_result := post_journal_entry(
        p_reversal_date,
        'REVERSAL: ' || COALESCE(p_memo, v_orig.memo, v_orig.code),
        v_orig.source_type,
        v_orig.id,
        v_lines
    );
    v_reversal_id := (v_result->>'entry_id')::uuid;

    UPDATE journal_entries
    SET status = 'reversed', reversed_by = v_reversal_id
    WHERE id = p_entry_id;

    RETURN jsonb_build_object(
        'reversal_id', v_reversal_id,
        'code', v_result->>'code'
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
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):一张费用单记的是【已经发生】的供应,日期晚于今天按名拒。
    IF p_expense_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|expense|%|%', p_expense_date, CURRENT_DATE;
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

-- ═══ db/functions/record_freight_document.sql ═══
CREATE OR REPLACE FUNCTION public.record_freight_document(p_doc_date date, p_supplier_id uuid, p_amount numeric, p_currency text, p_allocation_basis text, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text, p_allocations jsonb DEFAULT NULL::jsonb, p_notes text DEFAULT NULL::text, p_gst_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_doc_id    uuid := gen_random_uuid();
    v_code      text;
    v_year      integer;
    v_seq       integer;
    v_fx        numeric;
    v_base      numeric;
    v_bank      text;
    v_el        jsonb;
    v_batch     record;
    v_ids       uuid[] := ARRAY[]::uuid[];
    v_units     text[];
    v_basis_tot numeric := 0;
    v_stated    numeric := 0;
    v_share     numeric;
    v_basis_qty numeric;
    v_ratio     numeric;
    v_inv_tot   numeric := 0;
    v_cost_tot  numeric := 0;
    v_alloc_tot numeric := 0;
    v_lines     jsonb := '[]'::jsonb;
    v_je        jsonb;
    v_rows      jsonb := '[]'::jsonb;
    v_last      uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- ★★ PAY-REQ-1(Tim 的 Q2(c),2026-09-23):运费单【不许生下来就是已付】——
    --   'paid' 直接贷银行、不经 payments / SOD / 批准,是一扇侧门。从此一律挂账,
    --   钱经付款申请 → CFO 批准 → 付款离开。下面 'paid' 那一支因此到不了。
    --   (放在最前面:它是一句【不论单据内容】都成立的拒绝,不该排在批次校验后面。)
    IF p_payment_status = 'paid' THEN
        RAISE EXCEPTION 'FREIGHT_PAID_AT_CREATION_REFUSED'
          USING HINT = '运费单先挂账(未付),再提付款申请、经 CFO 批准后付款(PAY-REQ-1)';
    END IF;

    -- ── 必填项:日期决定期间与汇率,绝不默认(FIN-10)────────────────────────
    IF p_doc_date IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_DATE_REQUIRED';
    END IF;
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):运费单记的是【已经发生】的一笔运费(FRT-2027-0001…0003 就是没有这道闸时进的真账,还占掉了 2027 年的无缝编号),日期晚于今天按名拒。
    IF p_doc_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|freight|%|%', p_doc_date, CURRENT_DATE;
    END IF;
    IF p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_SUPPLIER_REQUIRED';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'FREIGHT_AMOUNT_INVALID';
    END IF;
    IF p_allocation_basis IS NULL OR p_allocation_basis NOT IN ('weight','value','stated') THEN
        RAISE EXCEPTION 'FREIGHT_BASIS_INVALID|%', COALESCE(p_allocation_basis, '?');
    END IF;
    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array'
       OR jsonb_array_length(p_allocations) = 0 THEN
        RAISE EXCEPTION 'FREIGHT_NO_BATCHES';
    END IF;

    -- ── GST 是一道闸门,不是一句备注 ─────────────────────────────────────────
    -- 进口 GST 是【可抵扣的进项税】(1400):资本化它会同时高估存货【并】毁掉抵扣。
    -- 今天 gst_registered = false、税率 0,所以这里直接点名拒收。
    -- 【登记之后该怎么走,写在这里而不是留给人猜】:GST 部分单独借 1400、
    -- 不参与任何分摊,只有净额进 1200/5000。
    IF p_gst_amount IS NOT NULL AND p_gst_amount <> 0 THEN
        RAISE EXCEPTION 'FREIGHT_GST_NOT_CAPITALISABLE|%', p_gst_amount;
    END IF;

    IF p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'FREIGHT_PAYMENT_STATUS_INVALID|%', p_payment_status;
    END IF;
    IF p_payment_status = 'paid' THEN
        v_bank := COALESCE(p_bank_account, bank_account_for_currency(p_currency));
        IF v_bank IS NULL THEN
            RAISE EXCEPTION 'BANK_ACCOUNT_REQUIRED';
        END IF;
    ELSE
        v_bank := NULL;
    END IF;

    -- ── 汇率:本位币免换算;外币按【单据日】的行方卖出价(我们付钱出去)──────
    IF p_currency = base_currency_code() THEN
        v_fx := 1;
    ELSE
        v_fx := fx_rate_for(p_currency, p_doc_date, 'tt_sell');
    END IF;
    v_base := round(p_amount * v_fx, 2);

    -- ── 批次集合:先取回来,顺便验单位与货值 ─────────────────────────────────
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_last := (v_el->>'inbound_batch_id')::uuid;
        IF v_last = ANY (v_ids) THEN
            RAISE EXCEPTION 'FREIGHT_DUPLICATE_BATCH|%', v_last;
        END IF;
        SELECT ib.id, ib.code, ib.quantity, ib.unit, ib.unit_price, ib.remaining_qty
        INTO v_batch
        FROM inbound_batches ib WHERE ib.id = v_last AND ib.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(v_last::text, '?');
        END IF;
        v_ids   := v_ids || v_batch.id;
        v_units := COALESCE(v_units, ARRAY[]::text[]) || v_batch.unit;

        IF p_allocation_basis = 'weight' THEN
            v_basis_tot := v_basis_tot + v_batch.quantity;
        ELSIF p_allocation_basis = 'value' THEN
            -- 【未计价批次:点名拒绝,不给零份额】零份额等于把它那部分运费悄悄
            -- 摊到别的批次头上,而那是一个没人看得见的错误 —— 正是资本化的代价所在。
            IF v_batch.unit_price IS NULL THEN
                RAISE EXCEPTION 'FREIGHT_BATCH_UNPRICED|%', v_batch.code;
            END IF;
            v_basis_tot := v_basis_tot + v_batch.quantity * v_batch.unit_price;
        ELSE
            IF (v_el->>'amount_base') IS NULL THEN
                RAISE EXCEPTION 'FREIGHT_STATED_AMOUNT_REQUIRED|%', v_batch.code;
            END IF;
            IF (v_el->>'amount_base')::numeric < 0 THEN
                RAISE EXCEPTION 'FREIGHT_STATED_AMOUNT_INVALID|%', v_batch.code;
            END IF;
            v_stated := v_stated + (v_el->>'amount_base')::numeric;
        END IF;
    END LOOP;

    -- weight:跨不同单位的"按重量分"没有意义 —— 拒绝,不是近似
    IF p_allocation_basis = 'weight'
       AND (SELECT count(DISTINCT u) FROM unnest(v_units) u) > 1 THEN
        RAISE EXCEPTION 'FREIGHT_MIXED_UNITS|%', array_to_string(
            ARRAY(SELECT DISTINCT u FROM unnest(v_units) u ORDER BY 1), ',');
    END IF;
    IF p_allocation_basis IN ('weight','value') AND COALESCE(v_basis_tot, 0) <= 0 THEN
        RAISE EXCEPTION 'FREIGHT_BASIS_ZERO|%', p_allocation_basis;
    END IF;
    -- stated:必须【正好】加总到单据金额。差一分就拒 —— 单据自己列明了,
    -- 对不上就是抄错了,而"差一点"在存货里同样看不见。
    IF p_allocation_basis = 'stated' AND round(v_stated, 2) <> v_base THEN
        RAISE EXCEPTION 'FREIGHT_STATED_SUM_MISMATCH|%|%', round(v_stated, 2), v_base;
    END IF;

    -- ── 无缝编号(同 EXP/JE 手法)────────────────────────────────────────────
    v_year := EXTRACT(YEAR FROM p_doc_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('freight_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM freight_documents WHERE code LIKE document_type_prefix('freight_document') || '-' || v_year::text || '-%';
    v_code := document_type_prefix('freight_document') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- ── 单据先落地,分录号后补 ───────────────────────────────────────────────
    -- 【顺序是被外键逼出来的,不是风格】freight_allocations 的外键指向本单,
    -- 所以分摊行不可能先于单据存在。record_expense 是"先过分录再插单据",
    -- 那条顺序在这里【不成立】—— 照抄它就是第一版那个外键错。
    -- LOG-4a:direction 是【字面量 'inbound'】。这个函数没有出境分支,
    -- 出境走 record_export_freight_document —— 进料臂因此逐字节不动。
    INSERT INTO freight_documents (id, code, doc_date, supplier_id, amount_ccy, currency,
        fx_rate, amount_base, allocation_basis, payment_status, bank_account_code,
        notes, created_by, updated_by, direction)
    VALUES (v_doc_id, v_code, p_doc_date, p_supplier_id, p_amount, p_currency,
        v_fx, v_base, p_allocation_basis, p_payment_status, v_bank,
        p_notes, v_user, v_user, 'inbound');

    -- ── 逐批分摊 + 拆账 ─────────────────────────────────────────────────────
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        SELECT ib.id, ib.code, ib.quantity, ib.unit_price, ib.remaining_qty
        INTO v_batch FROM inbound_batches ib WHERE ib.id = (v_el->>'inbound_batch_id')::uuid;

        IF p_allocation_basis = 'weight' THEN
            v_basis_qty := v_batch.quantity;
            v_share := round(v_base * v_batch.quantity / v_basis_tot, 2);
        ELSIF p_allocation_basis = 'value' THEN
            v_basis_qty := round(v_batch.quantity * v_batch.unit_price, 2);
            v_share := round(v_base * (v_batch.quantity * v_batch.unit_price) / v_basis_tot, 2);
        ELSE
            -- stated:金额是人直接列明的,没有可再导出的中间量 —— basis_qty 留空。
            v_basis_qty := NULL;
            v_share := round((v_el->>'amount_base')::numeric, 2);
        END IF;

        -- 【拆账比例取此刻】迟到的运费是主路径;收货即到就是 ratio = 1。
        v_ratio := CASE WHEN v_batch.quantity = 0 THEN 1
                        ELSE LEAST(1, GREATEST(0, v_batch.remaining_qty / v_batch.quantity)) END;

        INSERT INTO freight_allocations (freight_document_id, inbound_batch_id,
                                         amount_base, basis_qty, in_stock_ratio, created_by)
        VALUES (v_doc_id, v_batch.id, v_share, v_basis_qty, round(v_ratio, 6), v_user);

        v_inv_tot  := v_inv_tot + round(v_share * v_ratio, 2);
        v_cost_tot := v_cost_tot + (v_share - round(v_share * v_ratio, 2));
        v_alloc_tot := v_alloc_tot + v_share;
        v_rows := v_rows || jsonb_build_object(
            'inbound_batch_id', v_batch.id, 'batch_code', v_batch.code,
            'amount_base', v_share, 'basis_qty', v_basis_qty,
            'in_stock_ratio', round(v_ratio, 6));
    END LOOP;

    -- 取整误差归到最后一批 —— 分摊之和必须【等于】单据金额,不是约等于
    IF v_alloc_tot <> v_base THEN
        UPDATE freight_allocations
           SET amount_base = amount_base + (v_base - v_alloc_tot)
         WHERE freight_document_id = v_doc_id AND inbound_batch_id = v_last;
        SELECT in_stock_ratio INTO v_ratio FROM freight_allocations
         WHERE freight_document_id = v_doc_id AND inbound_batch_id = v_last;
        v_inv_tot  := v_inv_tot + round((v_base - v_alloc_tot) * v_ratio, 2);
        v_cost_tot := v_base - v_inv_tot;
    END IF;

    -- ── 过账。借:在库 1200 / 已耗 5000;贷:【货代】—— 已付走银行,未付走 2000 ──
    IF round(v_inv_tot, 2) <> 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '1200', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', round(v_inv_tot, 2),
            'line_memo', 'freight — in-stock share');
    END IF;
    IF round(v_cost_tot, 2) <> 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '5000', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', round(v_cost_tot, 2),
            'line_memo', 'freight — consumed share');
    END IF;
    v_lines := v_lines || jsonb_build_object(
        'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
        'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx,
        'line_memo', 'freight payable — forwarder');

    v_je := post_journal_entry(p_doc_date,
        'Freight ' || v_code, 'freight', v_doc_id, v_lines);

    UPDATE freight_documents SET journal_entry_id = (v_je->>'entry_id')::uuid
     WHERE id = v_doc_id;

    RETURN jsonb_build_object(
        'freight_document_id', v_doc_id, 'code', v_code,
        'amount_base', v_base, 'allocation_basis', p_allocation_basis,
        'in_stock_base', round(v_inv_tot, 2), 'consumed_base', round(v_cost_tot, 2),
        'entry_id', v_je->>'entry_id', 'allocations', v_rows);
END;
$function$;

-- ═══ db/functions/record_export_freight_document.sql ═══
CREATE OR REPLACE FUNCTION public.record_export_freight_document(p_doc_date date, p_supplier_id uuid, p_amount numeric, p_currency text, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text, p_container_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_doc_id uuid := gen_random_uuid();
    v_code   text;
    v_year   integer;
    v_seq    integer;
    v_fx     numeric;
    v_base   numeric;
    v_bank   text;
    v_ctr    text;
    v_lines  jsonb := '[]'::jsonb;
    v_je     jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- ★★ PAY-REQ-1(Tim 的 Q2(c),2026-09-23):运费单【不许生下来就是已付】——
    --   'paid' 直接贷银行、不经 payments / SOD / 批准,是一扇侧门。从此一律挂账,
    --   钱经付款申请 → CFO 批准 → 付款离开。下面 'paid' 那一支因此到不了。
    --   (放在最前面:它是一句【不论单据内容】都成立的拒绝,不该排在批次校验后面。)
    IF p_payment_status = 'paid' THEN
        RAISE EXCEPTION 'FREIGHT_PAID_AT_CREATION_REFUSED'
          USING HINT = '运费单先挂账(未付),再提付款申请、经 CFO 批准后付款(PAY-REQ-1)';
    END IF;

    -- ── 必填项,与进料侧同一条规矩(FIN-10):日期决定期间与汇率,绝不默认 ────
    IF p_doc_date IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_DATE_REQUIRED';
    END IF;
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):运费单记的是【已经发生】的一笔运费(FRT-2027-0001…0003 就是没有这道闸时进的真账,还占掉了 2027 年的无缝编号),日期晚于今天按名拒。
    IF p_doc_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|export_freight|%|%', p_doc_date, CURRENT_DATE;
    END IF;
    IF p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_SUPPLIER_REQUIRED';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'FREIGHT_AMOUNT_INVALID';
    END IF;
    IF p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'FREIGHT_PAYMENT_STATUS_INVALID|%', p_payment_status;
    END IF;
    IF p_payment_status = 'paid' THEN
        v_bank := COALESCE(p_bank_account, bank_account_for_currency(p_currency));
        IF v_bank IS NULL THEN
            RAISE EXCEPTION 'BANK_ACCOUNT_REQUIRED';
        END IF;
    ELSE
        v_bank := NULL;
    END IF;

    -- ── 箱子可空;【指了就必须指得中】────────────────────────────────────────
    -- 单据是钱的对象(Tim 定),所以不指也成立:货代一张账单可能覆盖几个箱子,
    -- 也可能在箱子建档之前就到。但指向一个不存在或已注销的箱子,是一条
    -- 【看起来有出处、其实没有】的记录 —— 那比不指更坏。
    IF p_container_id IS NOT NULL THEN
        SELECT code INTO v_ctr FROM containers
         WHERE id = p_container_id AND deleted_at IS NULL;
        IF v_ctr IS NULL THEN
            RAISE EXCEPTION 'EXPORT_FREIGHT_CONTAINER_NOT_FOUND|%', p_container_id
              USING HINT = '这个箱子不存在,或者已经注销了 —— 指向它的运费单会带着一个查不回去的出处';
        END IF;
    END IF;

    -- ── 汇率:与进料侧【同一条】—— 单据日的行方卖出价(我们付钱出去)─────────
    IF p_currency = base_currency_code() THEN
        v_fx := 1;
    ELSE
        v_fx := fx_rate_for(p_currency, p_doc_date, 'tt_sell');
    END IF;
    v_base := round(p_amount * v_fx, 2);

    -- ── 无缝编号:【与进料侧同一个 FRT- 号段】(Tim 定)。同一把 advisory 锁,
    --    所以两个方向并发取号也不会撞 —— 号段是一条,不是两条。
    v_year := EXTRACT(YEAR FROM p_doc_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('freight_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM freight_documents WHERE code LIKE document_type_prefix('freight_document') || '-' || v_year::text || '-%';
    v_code := document_type_prefix('freight_document') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- allocation_basis 在本表是 NOT NULL,而出境单据【没有分摊】。
    -- 'stated' 是三个取值里唯一一个不意味着"由系统算一个分法"的:它的意思是
    -- "金额是人直接列明的,没有可再导出的中间量" —— 对一张不分摊的单据,
    -- 这恰好是真话。写 'weight' 或 'value' 才是编造一个从未发生的口径。
    INSERT INTO freight_documents (id, code, doc_date, supplier_id, amount_ccy, currency,
        fx_rate, amount_base, allocation_basis, payment_status, bank_account_code,
        notes, created_by, updated_by, direction, container_id)
    VALUES (v_doc_id, v_code, p_doc_date, p_supplier_id, p_amount, p_currency,
        v_fx, v_base, 'stated', p_payment_status, v_bank,
        p_notes, v_user, v_user, 'outbound', p_container_id);

    -- ── 过账:借 6300(运输物流费,expense)/ 贷 2000 或银行 ─────────────────
    -- 【1200 与 5000 在这个函数里一次都没有出现】,这不是巧合,是本刀的全部内容。
    -- 出口运费不是落地成本:它没有一个"这批货还剩多少在库"可读,
    -- 也没有一个批次该背它 —— 给它编一个,就是把它藏进存货。
    v_lines := jsonb_build_array(
        jsonb_build_object('account_code', '6300', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', v_base,
            'line_memo', 'export freight' || COALESCE(' — ' || v_ctr, '')),
        jsonb_build_object(
            'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
            'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx,
            'line_memo', 'export freight payable — forwarder'));

    v_je := post_journal_entry(p_doc_date,
        'Export freight ' || v_code, 'freight', v_doc_id, v_lines);

    UPDATE freight_documents SET journal_entry_id = (v_je->>'entry_id')::uuid
     WHERE id = v_doc_id;

    RETURN jsonb_build_object(
        'freight_document_id', v_doc_id, 'code', v_code, 'direction', 'outbound',
        'amount_base', v_base, 'expense_account', '6300',
        'container_id', p_container_id, 'container_code', v_ctr,
        'entry_id', v_je->>'entry_id');
END;
$function$;

-- ═══ db/functions/create_invoice.sql ═══
-- db/functions/create_invoice.sql
-- GST-2(2026-08-25):发票开始【携带税】,并过一张【只有税】的分录。
-- 此前它读 finance_settings.gst_rate_pct 这个标量算税、且一张分录都不过。
-- 标量表达不了税率史(2022 年那张票永远是 7%),也表达不了零税率 / 豁免 /
-- 不在范围内这三件税率都为零、进的格子却完全不同的事。
-- 【分录只过税】收入在【销售】那一刻已经认过(借 1100 / 贷 4000);
-- 开票再认一次就是把同一笔生意记两遍。而税从来没有人过过 ——
-- invoices.total_base 一直写着 subtotal + tax,这张分录是第一次在总账里兑现它。
-- 【税码与税率冻在行上】已开出的发票永不按今天的设置重算它的税。
CREATE OR REPLACE FUNCTION public.create_invoice(p_customer_id uuid, p_sales_record_ids uuid[], p_issue_date date DEFAULT NULL::date, p_payment_terms_days integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text, p_tax_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cust        customers%ROWTYPE;
    -- PARTY-1:开票快照里的联系人 —— 取本客户的【主联系人】那一行
    v_contact     counterparty_contacts%ROWTYPE;
    v_issue       date := COALESCE(p_issue_date, CURRENT_DATE);
    v_terms       integer;
    v_due         date;
    v_invoice_id  uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_code        text;
    v_sale_id     uuid;
    v_seen        uuid[] := ARRAY[]::uuid[];
    v_sale        record;
    v_currency    text;
    v_no          integer := 0;
    v_subtotal    numeric := 0;
    v_tax_code    text;
    v_tax_rate    numeric := 0;
    v_tax         numeric := 0;
    v_line_tax    numeric;
    v_existing    text;
    v_base        text;
    v_je          jsonb;
    v_entry_id    uuid;
    v_lines       jsonb := '[]'::jsonb;  -- 第一趟收集,第二趟落库
    v_line        jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    -- 1. 客户
    SELECT * INTO v_cust FROM customers
    WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    -- PARTY-1:主联系人。**没有也不拒绝** —— 一张开给没填联系人的客户的发票
    -- 一直都是合法的,本刀不顺手把它变成一道新闸(那会是一次没人裁定过的收紧)。
    -- 没有时 v_contact 的三个字段是 NULL,快照里那三个键就是 NULL。
    SELECT * INTO v_contact FROM counterparty_contacts
     WHERE customer_id = v_cust.id AND is_primary AND deleted_at IS NULL;

    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):税点就是开票日,一张明天的发票会把销项税记进一个还没到的期间,日期晚于今天按名拒。
    IF v_issue > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|invoice|%|%', v_issue, CURRENT_DATE;
    END IF;
    IF p_sales_record_ids IS NULL OR array_length(p_sales_record_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- ★★【2. 账期:显式 > 客户设定 > 【按名拒】—— 原来这里兜底 30 天】★★
    --   **PARTY-1(2026-08-29)把那个 30 拿掉了,而它不是一个装饰性的默认值。**
    --   实测:线上三个客户 payment_terms_days 全是 NULL,于是【九张发票无一例外】
    --   带着一个编出来的 30 天账期 —— 而 due_date 喂着 ar_aging_asof、
    --   customer_statement_data(对账单【与】催收,催收还把它冻起来)与
    --   cash_forecast_data。**一个编出来的到期日于是同时进了四个看起来权威的地方。**
    --   这是 FIN-10 那条规矩换了身衣服:那条说"决定期间的【日期】不许有默认值",
    --   这里是"决定到期日的【账期】不许有默认值"。
    --   【为什么不回填】把 30 写进客户主数据,就是把我的猜测变成一条永久的、
    --   而且再也标不出来的事实。已经开出去的九张单【保留】它们的 30 ——
    --   那是当时发出去的东西,历史不改写。
    v_terms := COALESCE(p_payment_terms_days, v_cust.payment_terms_days);
    IF v_terms IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_PAYMENT_TERMS_NOT_SET|%|%', v_cust.code, v_cust.legal_name
          USING HINT = '这张发票的到期日没有来路:客户主数据里没有付款账期,这次调用也没有给一个。去【客户 → 编辑】把「付款账期(天)」填上,或者在开票时明确指定一个 —— 系统不再替你假设 30 天。';
    END IF;
    IF v_terms < 0 THEN
        RAISE EXCEPTION 'TERMS_INVALID|%', v_terms;
    END IF;
    v_due := v_issue + v_terms;

    -- ════════════════════════════════════════════════════════════════════════
    -- 3. 【税点在这里】GST-2:税码经"往来对象默认 + 本单改写"解析,
    --    税率按【这张发票自己的开票日】解析 —— 两者一起冻在行上。
    -- ════════════════════════════════════════════════════════════════════════
    IF gst_registered() THEN
        v_tax_code := resolve_tax_code(p_tax_code, v_cust.default_tax_code, 'output', 'customer');
        v_tax_rate := tax_rate_for(v_tax_code, v_issue);
    ELSE
        -- 【未注册:与建 GST 之前一模一样】不解析、不盖码、不过分录。
        -- 【但传了码要按名拒,不能悄悄忽略】悄悄忽略会让一个以为自己在计税的人
        -- 以为计了 —— 而屏幕上一切正常。
        IF NULLIF(btrim(COALESCE(p_tax_code, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'GST_NOT_REGISTERED|%', p_tax_code;
        END IF;
        v_tax_code := NULL;
        v_tax_rate := 0;
    END IF;

    -- 4. 无缝编号(按 issue_date 的年份),咨询锁串行化;回滚即释放号码
    v_year := EXTRACT(YEAR FROM v_issue)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('invoice_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM invoices
    WHERE code LIKE document_type_prefix('invoice') || '-' || v_year::text || '-%';
    v_code := document_type_prefix('invoice') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 5. 第一趟:逐张销售校验(存在 → 归属 → 未被占用 → 币种一致)并累计金额。
    FOREACH v_sale_id IN ARRAY p_sales_record_ids
    LOOP
        IF v_sale_id = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_SALE|%',
                COALESCE((SELECT ob.code FROM sales_records sr
                          JOIN output_batches ob ON ob.id = sr.output_batch_id
                          WHERE sr.id = v_sale_id), v_sale_id::text);
        END IF;
        v_seen := v_seen || v_sale_id;

        SELECT sr.id, sr.customer_id, sr.quantity, sr.unit_price, sr.currency,
               sr.amount_base, ob.code AS batch_code, ob.unit, m.name AS material_name
        INTO v_sale
        FROM sales_records sr
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        LEFT JOIN materials m ON m.id = ob.material_id
        WHERE sr.id = v_sale_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SALE_NOT_FOUND|%', v_sale_id;
        END IF;

        -- sales_records.customer_id 可空 —— 批次可能在客户还没登记时就卖了。
        -- SAL-C:【但无主的销售不能开给客户】。开票是对外声称"这个人欠这笔钱";
        -- 声称之前,销售自己得先记下这件事。出路是先补挂
        -- (attribute_sale_customer),不是在这里默认它属于收票人。
        IF v_sale.customer_id IS NULL THEN
            RAISE EXCEPTION 'SALE_NOT_ATTRIBUTED|%', v_sale.batch_code;
        END IF;
        IF v_sale.customer_id <> p_customer_id THEN
            RAISE EXCEPTION 'SALE_WRONG_CUSTOMER|%', v_sale.batch_code;
        END IF;

        SELECT i.code INTO v_existing
        FROM invoice_lines il
        JOIN invoices i ON i.id = il.invoice_id
        WHERE il.sales_record_id = v_sale_id AND NOT il.invoice_voided
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'ALREADY_INVOICED|%|%', v_sale.batch_code, v_existing;
        END IF;

        IF v_currency IS NULL THEN
            v_currency := v_sale.currency;
        ELSIF v_currency <> v_sale.currency THEN
            RAISE EXCEPTION 'MIXED_CURRENCY|%|%', v_currency, v_sale.currency;
        END IF;

        -- 【逐行算税、逐行取整,行加起来就是表头】口径与行金额一致:
        -- 表头的税 = Σ 行税,不是 round(Σ 行净额 × 税率) —— 两种算法差几分,
        -- 而客户手里那张纸上印的是行。
        v_line_tax := CASE WHEN v_tax_code IS NULL THEN 0
                           -- PO-GST-1:提取成 tax_amount_for(表达式逐字未变)。
                           ELSE tax_amount_for(v_sale.amount_base, v_tax_rate) END;

        v_no := v_no + 1;
        v_lines := v_lines || jsonb_build_object(
            'sales_record_id', v_sale_id,
            'line_no', v_no,
            'description', v_sale.batch_code || COALESCE(' — ' || v_sale.material_name, ''),
            'quantity', v_sale.quantity,
            'unit', v_sale.unit,
            'unit_price', v_sale.unit_price,
            'amount_base', v_sale.amount_base,
            'tax_base', v_line_tax);

        v_subtotal := v_subtotal + v_sale.amount_base;
        v_tax := v_tax + v_line_tax;
    END LOOP;

    v_subtotal := round(v_subtotal, 2);
    v_tax := round(v_tax, 2);

    -- ════════════════════════════════════════════════════════════════════════
    -- 6. 【只过税的那张分录】借 1100 应收 / 贷 2100 销项税。
    --    零税率 / 豁免 / 不在范围内(税额为 0)不过分录 —— 一条 0 的腿在分录上
    --    读起来像"这一段发生了但金额为零",而且 post_journal_entry 会拒。
    --    供应额本身【不在这张分录里】,它在发票行上;F5 的 box1 从那里推导。
    --    期间锁与年结闸由 post_journal_entry 对 v_issue 统一执行。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_tax <> 0 THEN
        v_je := post_journal_entry(
            v_issue,
            'Invoice ' || v_code || ' GST',
            'invoice', v_invoice_id,
            jsonb_build_array(
                jsonb_build_object('account_code', '1100', 'side', 'debit',
                    'currency', v_base, 'amount_ccy', v_tax,
                    'line_memo', 'output tax ' || v_tax_code),
                jsonb_build_object('account_code', '2100', 'side', 'credit',
                    'currency', v_base, 'amount_ccy', v_tax,
                    'line_memo', 'output tax ' || v_tax_code)));
        v_entry_id := (v_je->>'entry_id')::uuid;
    END IF;

    -- 7. 第二趟:金额已定,一次写对发票头,再落明细行。
    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_base, tax_rate_pct, tax_base, total_base,
                          notes, terms_text, bill_to_snapshot, entry_id)
    VALUES (v_invoice_id, v_code, p_customer_id, v_issue, v_due, v_terms,
            v_currency, v_subtotal, v_tax_rate, v_tax, round(v_subtotal + v_tax, 2),
            p_notes, p_terms_text,
            jsonb_build_object(
                'code', v_cust.code,
                'legal_name', v_cust.legal_name,
                'short_name', v_cust.short_name,
                'country', v_cust.country,
                'tax_id', v_cust.tax_id,
                'address', v_cust.address,
                'payment_terms', v_cust.payment_terms,
                'incoterm', v_cust.incoterm,
                -- ★【联系人从 counterparty_contacts 的【主联系人】取,不再从客户那三列取】★
                --   PARTY-1 把那三列搬进了子表并删掉。**已经存下来的快照不受影响**:
                --   它们是自成一体的 jsonb,记的是开票那一刻的事实 —— 变的只是
                --   【下一张】发票从哪儿取。没有主联系人时这三个键是 NULL,
                --   与本刀之前"客户没填联系人"的效果逐字一致。
                'contact_person', v_contact.name,
                'email', v_contact.email,
                'phone', v_contact.phone),
            v_entry_id);

    FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        INSERT INTO invoice_lines (invoice_id, sales_record_id, line_no, description,
                                   quantity, unit, unit_price, amount_base,
                                   tax_code, tax_rate_pct, tax_base)
        VALUES (v_invoice_id,
                (v_line->>'sales_record_id')::uuid,
                (v_line->>'line_no')::integer,
                v_line->>'description',
                (v_line->>'quantity')::numeric,
                v_line->>'unit',
                (v_line->>'unit_price')::numeric,
                (v_line->>'amount_base')::numeric,
                v_tax_code,
                CASE WHEN v_tax_code IS NULL THEN NULL ELSE v_tax_rate END,
                (v_line->>'tax_base')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'invoice_id', v_invoice_id,
        'code', v_code,
        'issue_date', v_issue,
        'due_date', v_due,
        'subtotal_base', v_subtotal,
        'tax_code', v_tax_code,
        'tax_rate_pct', v_tax_rate,
        'tax_base', v_tax,
        'total_base', round(v_subtotal + v_tax, 2),
        'line_count', v_no,
        'currency', v_currency,
        'journal_code', v_je->>'code'
    );
END;
$function$
;

-- ═══ db/functions/create_order_invoice.sql ═══
CREATE OR REPLACE FUNCTION public.create_order_invoice(p_sales_order_id uuid, p_issue_date date, p_payment_terms_days integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text, p_line_ids uuid[] DEFAULT NULL::uuid[], p_tax_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order    sales_orders%ROWTYPE;
    v_cust     customers%ROWTYPE;
    -- PARTY-1:开票快照里的联系人 —— 取本客户的【主联系人】那一行
    v_contact     counterparty_contacts%ROWTYPE;
    v_terms    integer;
    v_due      date;
    v_invoice_id uuid := gen_random_uuid();
    v_year     integer;
    v_seq      integer;
    v_code     text;
    v_line     record;
    v_no       integer := 0;
    v_sub_ccy  numeric := 0;
    v_sub_base numeric;
    v_tax_code text;
    v_tax_rate numeric := 0;
    v_tax      numeric := 0;      -- 单据币种
    v_tax_base numeric := 0;      -- 本位币
    v_line_tax numeric;
    v_existing text;
    v_exposure numeric;
    v_lines    jsonb := '[]'::jsonb;
    v_l        jsonb;
    v_je       jsonb;
    v_bad      int;
BEGIN
    -- 【权限:module.finance.edit,与 create_invoice 同一个码 —— 想过 B4(b) 那条路】
    -- "检查正在做的那件事"的规矩会指向 module.sales.edit(开票是订单流的一步);
    -- 但同一种单据(invoices)由两个码把门,是给下一个人埋的判断分叉 —— sale 头
    -- 已经是 finance.edit,而这张票【过账】,比 sale 头更财务而不是更不。
    -- 订单页上的按钮按持码与否显示/受限,不把人骗去撞一次拒绝。
    PERFORM require_permission('module.finance.edit');

    -- 【开票日必填 —— 它决定分录期间】sale 头的默认今天记录在
    -- docs/empty-string-to-rpc-audit.md(那种发票不过账);这张过账,按日期规矩拒。
    IF p_issue_date IS NULL THEN
        RAISE EXCEPTION 'INVOICE_DATE_REQUIRED';
    END IF;
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):这张发票开票即过账(借 1100),一个明天的日期就是一笔明天的应收与一个还没到的税点,日期晚于今天按名拒。
    IF p_issue_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|invoice|%|%', p_issue_date, CURRENT_DATE;
    END IF;

    SELECT * INTO v_order FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_id::text, '?');
    END IF;
    -- 【只对确认单开票】草稿还不是承诺;作废/关闭的单没有可开的东西。
    -- 【SO-3b:partially_shipped 同样算数】发了一部分的单仍然是活的,剩下的行
    -- 还要开票才发得出去 —— 与 reserve_stock 同一条(fixture 68 撞出来的)。
    IF v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_INVOICE_ORDER_NOT_CONFIRMED|%|%', v_order.code, v_order.status;
    END IF;

    -- 【客户是订单的客户,不是参数】—— 让开票替人改收票方,就是 SAL-C 修掉的
    -- 那种归属错位的反向版本。
    SELECT * INTO v_cust FROM customers WHERE id = v_order.customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', v_order.customer_id;
    END IF;

    -- PARTY-1:主联系人。**没有也不拒绝** —— 一张开给没填联系人的客户的发票
    -- 一直都是合法的,本刀不顺手把它变成一道新闸(那会是一次没人裁定过的收紧)。
    -- 没有时 v_contact 的三个字段是 NULL,快照里那三个键就是 NULL。
    SELECT * INTO v_contact FROM counterparty_contacts
     WHERE customer_id = v_cust.id AND is_primary AND deleted_at IS NULL;

    -- ★【账期不再兜底 30 天 —— 见 create_invoice 同一处的长注释】★
    --   两扇门必须同时改:只改一扇,那个编出来的到期日会从另一扇原样走出来,
    --   而两扇门都通向同一张 invoices 表(「闸要拦在今天所有的入口上」)。
    v_terms := COALESCE(p_payment_terms_days, v_cust.payment_terms_days);
    IF v_terms IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_PAYMENT_TERMS_NOT_SET|%|%', v_cust.code, v_cust.legal_name
          USING HINT = '这张发票的到期日没有来路:客户主数据里没有付款账期,这次调用也没有给一个。去【客户 → 编辑】把「付款账期(天)」填上,或者在开票时明确指定一个 —— 系统不再替你假设 30 天。';
    END IF;
    IF v_terms < 0 THEN
        RAISE EXCEPTION 'TERMS_INVALID|%', v_terms;
    END IF;
    v_due := p_issue_date + v_terms;

    -- 【显式子集必须整个属于这张单】—— 混进别的单的行 id,静默跳过等于把
    -- "开了哪些行"变成猜测。
    IF p_line_ids IS NOT NULL THEN
        SELECT count(*) INTO v_bad FROM unnest(p_line_ids) x
         WHERE NOT EXISTS (SELECT 1 FROM sales_order_lines l
                            WHERE l.id = x AND l.sales_order_id = p_sales_order_id);
        IF v_bad > 0 THEN
            RAISE EXCEPTION 'SO_INVOICE_LINE_INVALID|%|%', v_order.code, v_bad;
        END IF;
    END IF;

    FOR v_line IN
        SELECT l.id, l.line_no AS order_line_no, l.quantity, l.unit_price,
               m.code AS mat_code, m.name AS mat_name, m.unit AS mat_unit
        FROM sales_order_lines l
        JOIN materials m ON m.id = l.material_id
        WHERE l.sales_order_id = p_sales_order_id
          AND (p_line_ids IS NULL OR l.id = ANY (p_line_ids))
        ORDER BY l.line_no
    LOOP
        -- 友好检查;硬保证是 uq_invoice_lines_live_order_line(索引管正确性,
        -- 这里管可读性 —— 与销售侧 ALREADY_INVOICED 逐字同一个分工)。
        SELECT i.code INTO v_existing
        FROM invoice_lines il
        JOIN invoices i ON i.id = il.invoice_id
        WHERE il.sales_order_line_id = v_line.id AND NOT il.invoice_voided
        LIMIT 1;
        IF FOUND THEN
            IF p_line_ids IS NULL THEN
                CONTINUE;   -- "全部未开"的口径:已开的行自然跳过
            END IF;
            -- 点名要求开一条已开的行 → 按名拒,说出它在哪张票上
            RAISE EXCEPTION 'SO_LINE_ALREADY_INVOICED|%|%', v_line.order_line_no, v_existing;
        END IF;

        v_no := v_no + 1;
        v_lines := v_lines || jsonb_build_object(
            'sales_order_line_id', v_line.id,
            'line_no', v_no,
            'description', v_line.mat_code || ' — ' || v_line.mat_name,
            'quantity', v_line.quantity,
            'unit', v_line.mat_unit,
            'unit_price', v_line.unit_price,
            'amount_ccy', round(v_line.quantity * v_line.unit_price, 2));
        v_sub_ccy := v_sub_ccy + round(v_line.quantity * v_line.unit_price, 2);
    END LOOP;

    IF v_no = 0 THEN
        RAISE EXCEPTION 'SO_INVOICE_NOTHING_TO_BILL|%', v_order.code;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【GST-2:那条"明确不支持"的拒绝在这里退休 —— 因为它等的那个答案到了】
    -- 原话是"预收发票的销项税时点与科目没人回答过"。Tim 2026-08-25 的裁定
    -- 就是那个答案:税点是【开票】。而订单流发票【正是】一张先于发货开出的
    -- 税务发票 —— 也就是新加坡税点规则最典型的那一种。把它继续拒下去,
    -- 等于在开关打开的那一天关掉整条订单开票路。
    -- 【科目也随之确定】销项税贷 2100,与 sale 型逐字同一个落点。
    -- ════════════════════════════════════════════════════════════════════════
    IF gst_registered() THEN
        v_tax_code := resolve_tax_code(p_tax_code, v_cust.default_tax_code, 'output', 'customer');
        v_tax_rate := tax_rate_for(v_tax_code, p_issue_date);
    ELSE
        IF NULLIF(btrim(COALESCE(p_tax_code, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'GST_NOT_REGISTERED|%', p_tax_code;
        END IF;
        v_tax_code := NULL;
        v_tax_rate := 0;
    END IF;

    -- 【逐行算税、逐行取整】表头的税 = Σ 行税,不是 round(Σ 行净额 × 税率):
    -- 两种算法差几分,而客户手里那张纸上印的是行。与 create_invoice 同一口径。
    IF v_tax_code IS NOT NULL THEN
        DECLARE v_acc jsonb := '[]'::jsonb; v_e jsonb;
        BEGIN
            FOR v_e IN SELECT * FROM jsonb_array_elements(v_lines)
            LOOP
                -- PO-GST-1:提取成 tax_amount_for(表达式逐字未变)。
                v_line_tax := tax_amount_for((v_e->>'amount_ccy')::numeric, v_tax_rate);
                v_tax      := v_tax + v_line_tax;
                v_tax_base := v_tax_base + round(v_line_tax * v_order.fx_rate, 2);
                v_acc := v_acc || (v_e || jsonb_build_object('tax_ccy', v_line_tax));
            END LOOP;
            v_lines := v_acc;
        END;
        v_tax      := round(v_tax, 2);
        v_tax_base := round(v_tax_base, 2);
    END IF;

    v_sub_ccy := round(v_sub_ccy, 2);
    -- 头上的本位币额与分录同式:round(Σccy × fx)。行的 amount_base 逐行取整,
    -- 是显示口径 —— 头对分录,行对纸面,两者相差不超过几分且各自自洽。
    v_sub_base := round(v_sub_ccy * v_order.fx_rate, 2);

    -- 【信用闸在这里 —— 产生敞口的是开票】确认订单只看 credit_hold(那里的注释
    -- 说了为什么);额度对着"敞口 + 本票"判,敞口含已过账未结清的订单流发票
    -- (customer_ar_exposure_base 的第二项,本刀加的)。消息四个数说全,
    -- 与 record_output_sale 同形。
    IF v_cust.credit_hold THEN
        RAISE EXCEPTION 'CREDIT_HOLD|%', v_cust.code;
    END IF;
    IF v_cust.credit_limit_base IS NOT NULL THEN
        v_exposure := customer_ar_exposure_base(v_cust.id);
        -- 【敞口按客户真正欠的钱算 —— 含税】开票即应收,而应收是净额 + 销项税。
        -- 只按净额判额度,会让每一张票都少占用一截额度。
        IF v_exposure + v_sub_base + v_tax_base > v_cust.credit_limit_base THEN
            RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED|%|%|%|%',
                v_cust.code, v_cust.credit_limit_base, v_exposure, v_sub_base + v_tax_base;
        END IF;
    END IF;

    -- 【无缝编号,与 create_invoice 同一把锁】真正的互斥点是 advisory key
    -- 'invoice_code_<year>' 这个字符串 —— 两个函数必须逐字同一把;MAX+1 只是推导。
    v_year := EXTRACT(YEAR FROM p_issue_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('invoice_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM invoices WHERE code LIKE document_type_prefix('invoice') || '-' || v_year::text || '-%';
    v_code := document_type_prefix('invoice') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 【过账:借 1100 应收 / 贷 2500 合同负债】单据币种,按订单抄来的汇率。
    -- 期间锁/年结闸由 post_journal_entry 对 p_issue_date 统一执行。
    v_je := post_journal_entry(
        p_issue_date,
        'Invoice ' || v_code || ' · ' || v_order.code,
        'invoice', v_invoice_id,
        CASE WHEN v_tax = 0 THEN
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_sub_ccy, 'fx_rate', v_order.fx_rate),
            jsonb_build_object('account_code', '2500', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_sub_ccy, 'fx_rate', v_order.fx_rate))
        ELSE
        -- 【税是【第三、四条腿】,不是把 1100 那条腿加粗】两条独立取整的腿
        -- 精确对冲;把净额与税合成一条 round((净+税)×fx) 会与 2500/2100 两边
        -- 差一分钱,而那一分钱撞的是提交时的借贷平衡触发器。
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_sub_ccy, 'fx_rate', v_order.fx_rate),
            jsonb_build_object('account_code', '2500', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_sub_ccy, 'fx_rate', v_order.fx_rate),
            -- 【税那两条腿的 fx 用 v_tax_base / v_tax,不是订单汇率本身】
            -- 【为什么】F5 的 box6(单据侧)是 Σ 行税额(逐行 round(原币税 × fx)),
            -- 而这两条腿若按订单汇率过,过的是 round(Σ原币税 × fx) —— 外币下
            -- 两者可以差一分钱,于是"单据 vs 总账"那条勾稽会在一张【完全正确的】
            -- 发票上报 false。一条会因为取整而误报的勾稽,一个季度之后就没人看了。
            -- 【这个写法是仓库里现成的】record_payment 的解除行逐字同一手:
            -- "行 fx = 目标基准额 ÷ 原币额(除后反乘取整恰好还原)"。
            jsonb_build_object('account_code', '1100', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_tax, 'fx_rate', v_tax_base / v_tax,
                'line_memo', 'output tax ' || v_tax_code),
            jsonb_build_object('account_code', '2100', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_tax, 'fx_rate', v_tax_base / v_tax,
                'line_memo', 'output tax ' || v_tax_code))
        END);

    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_base, tax_rate_pct, tax_base, total_base,
                          notes, terms_text, bill_to_snapshot,
                          kind, sales_order_id, entry_id, fx_rate)
    VALUES (v_invoice_id, v_code, v_cust.id, p_issue_date, v_due, v_terms,
            v_order.currency, v_sub_base, v_tax_rate, v_tax_base, v_sub_base + v_tax_base,
            p_notes, p_terms_text,
            jsonb_build_object(
                'code', v_cust.code,
                'legal_name', v_cust.legal_name,
                'short_name', v_cust.short_name,
                'country', v_cust.country,
                'tax_id', v_cust.tax_id,
                'address', v_cust.address,
                'payment_terms', v_cust.payment_terms,
                'incoterm', v_cust.incoterm,
                -- ★【联系人从 counterparty_contacts 的【主联系人】取,不再从客户那三列取】★
                --   PARTY-1 把那三列搬进了子表并删掉。**已经存下来的快照不受影响**:
                --   它们是自成一体的 jsonb,记的是开票那一刻的事实 —— 变的只是
                --   【下一张】发票从哪儿取。没有主联系人时这三个键是 NULL,
                --   与本刀之前"客户没填联系人"的效果逐字一致。
                'contact_person', v_contact.name,
                'email', v_contact.email,
                'phone', v_contact.phone),
            'order', p_sales_order_id, (v_je->>'entry_id')::uuid, v_order.fx_rate);

    FOR v_l IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        INSERT INTO invoice_lines (invoice_id, sales_order_line_id, line_no, description,
                                   quantity, unit, unit_price, amount_base,
                                   tax_code, tax_rate_pct, tax_base)
        VALUES (v_invoice_id,
                (v_l->>'sales_order_line_id')::uuid,
                (v_l->>'line_no')::integer,
                v_l->>'description',
                (v_l->>'quantity')::numeric,
                v_l->>'unit',
                (v_l->>'unit_price')::numeric,
                round((v_l->>'amount_ccy')::numeric * v_order.fx_rate, 2),
                v_tax_code,
                CASE WHEN v_tax_code IS NULL THEN NULL ELSE v_tax_rate END,
                CASE WHEN v_tax_code IS NULL THEN 0
                     ELSE round((v_l->>'tax_ccy')::numeric * v_order.fx_rate, 2) END);
    END LOOP;

    -- 开票进订单的历史 —— 订单流先开票后发货,"开过没有"是看订单的人的问题。
    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (p_sales_order_id, 'invoiced', v_code, auth.uid());

    RETURN jsonb_build_object(
        'invoice_id', v_invoice_id,
        'code', v_code,
        'issue_date', p_issue_date,
        'due_date', v_due,
        'currency', v_order.currency,
        'fx_rate', v_order.fx_rate,
        'subtotal_ccy', v_sub_ccy,
        'tax_code', v_tax_code,
        'tax_ccy', v_tax,
        'tax_base', v_tax_base,
        'total_base', v_sub_base + v_tax_base,
        'line_count', v_no,
        'journal_code', v_je->>'code');
END;
$function$
;

-- ═══ db/functions/relieve_processing_accruals.sql ═══
-- db/functions/relieve_processing_accruals.sql
-- 真实发票冲抵【估算】应计(FIN-6 C)。一张水电/燃气账单盖住整月多个 run 的
-- 估算行 —— 【多对一,不要求一一对应】(C3)。分录:
--   借 2200 被清的应计合计;差额(实际 − 估算)借/贷该成本类型的 5xxx 行 ——
--   估算与实际的差落进【发票所在期间】的损益(既定);
--   贷 银行(已付)或 贷 2000 应付(挂账,须给供应商 —— 之后走正常收付款核销)。
-- 【差异不回摊到批次】(既定,写在迁移头):化验改的是批次自己的料价,回摊天经地义;
-- 水电是横跨多个 run 的公摊,它的差异不属于任何单一批次。本函数【一个字都不碰】
-- 批次成本、存货计价、COGS —— fixture 逐项断言。
-- 【结构性防重复】发票只从这里进账;record_expense 早已拒收 5xxx(ACCOUNT_NOT_EXPENSE,
-- 5xxx 是 cogs 型),被清过的应计行不能再清(COST_ENTRY_ALREADY_SETTLED)。
-- 一次冲抵限一个 cost_type(账单本来就是按类型来的;差异报表按类型分组)。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin6-relieve-processing-accruals.sql.

CREATE OR REPLACE FUNCTION public.relieve_processing_accruals(p_entry_ids uuid[], p_actual_amount numeric, p_expense_date date, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_accrued numeric := 0;
    v_type    text;
    v_n int := 0;
    v_e record;
    v_var numeric;
    v_bank text;
    v_lines jsonb;
    v_je jsonb;
    v_expense_id uuid := gen_random_uuid();
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_entry_ids IS NULL OR array_length(p_entry_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;
    IF p_actual_amount IS NULL OR p_actual_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;
    IF p_payment_status = 'unpaid' AND p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
    END IF;
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):这里直接写一张费用单(不经 record_expense),记的同样是【已经发生】的一张发票(Tim Batch B Q6),日期晚于今天按名拒。
    IF p_expense_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|expense|%|%', p_expense_date, CURRENT_DATE;
    END IF;

    FOR v_e IN SELECT * FROM processing_cost_entries WHERE id = ANY (p_entry_ids) FOR UPDATE
    LOOP
        IF v_e.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'COST_ENTRY_INVALID|%', v_e.id; END IF;
        IF NOT v_e.is_estimate THEN RAISE EXCEPTION 'COST_ENTRY_NOT_ESTIMATE|%', v_e.cost_type; END IF;
        IF v_e.remitted_at IS NOT NULL OR v_e.relieved_at IS NOT NULL THEN
            RAISE EXCEPTION 'COST_ENTRY_ALREADY_SETTLED|%', v_e.cost_type;
        END IF;
        IF v_type IS NULL THEN v_type := v_e.cost_type;
        ELSIF v_type <> v_e.cost_type THEN
            RAISE EXCEPTION 'RELIEF_MIXED_COST_TYPES|%|%', v_type, v_e.cost_type;
        END IF;
        v_accrued := round(v_accrued + v_e.amount_base, 2);
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 OR v_accrued <= 0 THEN RAISE EXCEPTION 'NO_LINES'; END IF;

    IF p_payment_status = 'paid' THEN
        v_bank := COALESCE(p_bank_account, '1000');
        IF v_bank NOT IN ('1000','1010') THEN RAISE EXCEPTION 'BANK_INVALID|%', v_bank; END IF;
    END IF;

    -- 借 2200 清应计;差额进当期 5xxx;贷 银行/应付 记实际
    v_var := round(p_actual_amount - v_accrued, 2);
    v_lines := jsonb_build_array(jsonb_build_object(
        'account_code', '2200', 'side', 'debit', 'currency', base_currency_code(),
        'amount_ccy', v_accrued, 'line_memo', 'clear accrued ' || v_type));
    IF v_var > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', fin_cost_account(v_type),
            'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', v_var,
            'line_memo', 'estimate-to-actual variance');
    ELSIF v_var < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', fin_cost_account(v_type),
            'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', -v_var,
            'line_memo', 'estimate-to-actual variance');
    END IF;
    v_lines := v_lines || jsonb_build_object(
        'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
        'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', p_actual_amount);

    -- 单据号:与 record_expense 同一套(advisory lock + 年内递增)
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || EXTRACT(YEAR FROM p_expense_date)::integer::text)::bigint);
    SELECT document_type_prefix('expense') || '-' || EXTRACT(YEAR FROM p_expense_date)::integer::text || '-' ||
           LPAD((COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1)::text, 4, '0')
    INTO v_code
    FROM expenses
    WHERE code LIKE document_type_prefix('expense') || '-' || EXTRACT(YEAR FROM p_expense_date)::integer::text || '-%';
    v_je := post_journal_entry(p_expense_date, 'Expense ' || v_code || ' ' || fin_cost_account(v_type),
                               'expense', v_expense_id, v_lines);

    -- 发票立成正常开支单据:挂账的走既有收付款核销;科目 = 该成本类型的 5xxx
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_expense_id, v_code, p_expense_date, fin_cost_account(v_type), p_actual_amount, 'SGD', 1,
            p_actual_amount, p_payment_status, v_bank, p_supplier_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, auth.uid());

    UPDATE processing_cost_entries
    SET relieved_at = p_expense_date, relief_expense_id = v_expense_id
    WHERE id = ANY (p_entry_ids);

    RETURN jsonb_build_object('expense_id', v_expense_id, 'expense_code', v_code,
        'journal_code', v_je->>'code', 'cost_type', v_type,
        'accrued_cleared', v_accrued, 'actual', p_actual_amount, 'variance', v_var, 'entries', v_n);
END;
$function$;

-- ═══ db/functions/allocate_processing_costs.sql ═══
CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Cost allocation. Metals with a usable price (deleted_at IS NULL, price_date <= run
-- process_date) contribute to metal value; metals WITHOUT one contribute 0 and are
-- recorded in allocation_snapshot.skipped_metals (the former missing-price hard error is gone).
-- NO_METAL_VALUE still blocks when the total metal value across all legs is 0.
-- (Phase 1 follow-up 1, 2026-07-03.)
-- cut 2a (2026-07-06): 10a 资本化分录(借 1220 / 贷 1200 材料 + 贷 5xxx 费用;
-- 重分摊 = 冲旧 + 重挂);10b 给无 COGS 的既有销售按原 sale_date 补挂 COGS。
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_default_index        text;
    v_skipped_metals       jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
    v_ct                   record;
    v_sale                 record;
    v_cap_lines            jsonb;
    v_cap_total            numeric;
    v_cap_je               jsonb;
    v_cap_entry_id         uuid;
    v_cogs                 numeric;
    v_cogs_je              jsonb;
    -- FIN-24:差额法用
    v_prior                jsonb;      -- 分摊前各产出腿的 allocated(差额的"已记录"侧)
    v_rec_src              jsonb;      -- 已记录的各来源(material / 各 cost_type)
    v_rec_total            numeric;
    v_by_source            jsonb;      -- 本次各来源(写进 snapshot,下次的"已记录")
    v_delta                numeric;
    v_leg                  record;
    v_d1220                numeric := 0;
    v_d5000                numeric := 0;
    v_d5200                numeric := 0;
    v_l1220                numeric;
    v_l5000                numeric;
    v_other                numeric;
    v_cred_total           numeric := 0;
    v_deb_total            numeric;
    v_cap_status           text;
    -- FIN-25:再加工
    v_material_in          numeric;   -- 进料批投料(→ 1200)
    v_material_re          numeric;   -- 产出批投料(→ 1220 解除上游)
    v_upstream_incomplete  boolean;
    v_re_without_price     integer;
    -- PROC-COST-1:状态改变型分支
    v_state_changing       boolean;
    v_sc_out_inputs        integer;
    v_sc_in_inputs         integer;
    v_sc_basis_total       numeric;
    v_sc_rows              jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- PROC-COST-1:那条"无处可落"的拒绝在这里【换成了真正的去处】——
    -- 状态改变型的分支在第 6 步之后(它需要 v_material / v_process 都已算出)。
    -- 仍然拒绝的四种情形在分支里逐一按名点出,理由见本迁移的 2e 段。

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost(FIN-25 起两路):进料批按 inbound.unit_price;产出批
    --    (再加工)按上游 processing_outputs.unit_cost_base。NULL 价照旧计 0 并
    --    计数 —— 【允许,不拒绝】:车间按天走,财务分摊按月走,拒绝会让车间等
    --    财务。零不静默:cost_incomplete 标记打在本单产出上,逐级传染(见 9c),
    --    上游补分摊后本单过期,重跑即修复。
    -- FRT-1:材料成本 = 【落地成本】,不只是单价 —— 单价 + 分摊到该批的单位运费。
    -- 运费资本化进批次之后,这里若仍只读 unit_price,运费就停在 1200/5000,
    -- 永远走不到产出批的 unit_cost_base,batch_margin 会继续停在运费之前的那个数
    -- (而运费那张分录本身完全正确)。这正是"资本化的错误藏在存货里"最具体的一种。
    SELECT COALESCE(SUM(pi.quantity_consumed
             * (COALESCE(ib.unit_price, 0)
                + CASE WHEN ib.quantity > 0 THEN batch_freight_base(ib.id) / ib.quantity ELSE 0 END
                -- PROC-COST-1:第三个成本组件 —— 该批身上已资本化的加工成本
                -- (放电等状态改变型工序留下的)。【不加这一项,成本就走不出去】:
                -- 它是进料批上的资本化成本【唯一】能到达损益表的那条路。
                + CASE WHEN ib.quantity > 0 THEN batch_processing_cost_base(ib.id) / ib.quantity ELSE 0 END)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material_in, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(po_up.unit_cost_base, 0)), 0),
           COUNT(*) FILTER (WHERE po_up.unit_cost_base IS NULL),
           COALESCE(bool_or(po_up.unit_cost_base IS NULL OR po_up.cost_incomplete), false)
      INTO v_material_re, v_re_without_price, v_upstream_incomplete
    FROM processing_inputs pi
    JOIN processing_outputs po_up ON po_up.output_batch_id = pi.output_batch_id
    WHERE pi.run_id = p_run_id;
    v_inputs_without_price := v_inputs_without_price + COALESCE(v_re_without_price, 0);
    v_material := v_material_in + v_material_re;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_base), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-COST-1:【状态改变型 —— 成本资本化回投料批】
    -- 没有产出腿,于是收件人是那批【还在那里的】原料本身。深度放电不产出任何
    -- 新东西:料进去、料出来,只是不带电了 —— 所以它仍然是原料,成本落在 1200。
    -- 【只有加工成本资本化,材料成本【不】动】那批料的价值早就在 1200 上了;
    -- 再借一次 1200 就是拿 1200 对自己重复计数。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT NOT k.produces_outputs INTO v_state_changing
      FROM operation_types ot
      JOIN operation_kinds k ON k.code = ot.kind_code
     WHERE ot.code = v_run.operation_type_code;
    v_state_changing := COALESCE(v_state_changing, false);

    IF v_state_changing THEN
        -- 【拒绝 1】金属价值基准按【产出批的金属含量】拆分,而这里没有产出批。
        -- 那不是"算出来是零",是那个基准在这里根本没有可读的数。
        IF v_basis = 'metal_value' THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_BASIS|%|%', v_run.code, v_basis
              USING HINT = '金属价值基准读的是产出批的金属含量(output_batch_metals),而状态改变型工序没有产出批。按质量(weight)分摊。';
        END IF;

        SELECT count(*) FILTER (WHERE pi.output_batch_id IS NOT NULL),
               count(*) FILTER (WHERE pi.inbound_batch_id IS NOT NULL)
          INTO v_sc_out_inputs, v_sc_in_inputs
          FROM processing_inputs pi
         WHERE pi.run_id = p_run_id;

        -- 【拒绝 2】成本载体按 inbound_batch_id 记地址,自产产出批不在那个地址空间里。
        -- **按名拒绝,不许悄悄把成本丢掉** —— 要建这条路,先决定产出批的资本化载体
        -- 是什么(产出批已有 unit_cost_base,那是另一种形状,不是这一张台账)。
        IF v_sc_out_inputs > 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_OUTPUT_INPUT|%|%', v_run.code, v_sc_out_inputs
              USING HINT = '成本载体 batch_processing_cost_allocations 按进料批记地址,自产产出批不在它的地址空间里。这条路要建,先决定产出批的资本化载体是什么 —— 在那之前按名拒绝,而不是悄悄把这笔成本丢掉。';
        END IF;

        -- 【拒绝 3】没有投料批,资本化没有收件人。
        IF v_sc_in_inputs = 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_NO_INPUT|%', v_run.code
              USING HINT = '这张单没有进料批投料,资本化没有收件人。';
        END IF;

        SELECT COALESCE(SUM(pi.quantity_consumed), 0) INTO v_sc_basis_total
          FROM processing_inputs pi
         WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL;
        IF v_sc_basis_total <= 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_NO_BASIS|%', v_run.code
              USING HINT = '投料量合计为零,按质量分摊没有可用的分母。';
        END IF;

        -- 【拒绝 4 与既有路径同一条】资本化分录被人工冲销 → 基准与总账已分道。
        IF v_run.capitalization_entry_id IS NOT NULL THEN
            SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
            IF v_cap_status <> 'posted' THEN
                RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
            END IF;
            -- 【重分摊 = 冲旧 + 重挂,而这在这里是安全的 —— 论证只在这里成立】
            -- FIN-24 禁止转化型这么做,是因为成本已顺着产出批流向已售份额,而已过账
            -- 的 COGS 从不重述。状态改变型【没有产出批】:成本停在 1200 上一批仍然
            -- 是原料的货上,没有任何下游把它当成本消费掉。若那批料后来被一张转化型
            -- 加工单吃掉,那张单会因【第七过期源】而过期,重跑即修正。
            PERFORM reverse_journal_entry_internal(v_run.capitalization_entry_id,
                reversal_date_for(v_run.capitalization_entry_id),
                'Re-allocation ' || v_run.code);
            UPDATE processing_runs
               SET capitalization_entry_id = NULL, capitalized_cost_base = 0
             WHERE id = p_run_id;
        END IF;

        -- ── 台账:先删后插(幂等)。按投料量拆,最大份额吸收进位余数 ────────────
        -- 【零成本不写行 —— 一面为零而举的旗,等于喊狼来了】fu3:载体行是
        -- 第七过期源。一张【一分钱成本都没有】的放电单若也写下载体行,
        -- 它会把吃过那批料的下游单标成过期 —— 而那张单要重跑出来的数
        -- 与它现在的数【一模一样】。本仓库对无条件举旗已有成文处置
        -- (fixture 54:含量没变就不举旗,"没人看的旗和没有旗是同一样东西")。
        -- 【先删仍然无条件执行】:300 → 0 的重分摊必须真的把那一行拿掉。
        DELETE FROM batch_processing_cost_allocations WHERE run_id = p_run_id;

        IF round(v_process, 2) <> 0 THEN
        WITH legs AS (
            SELECT pi.inbound_batch_id AS ib, SUM(pi.quantity_consumed) AS q
              FROM processing_inputs pi
             WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL
             GROUP BY pi.inbound_batch_id
        ),
        calc AS (
            SELECT ib, q,
                   round(v_process * q / v_sc_basis_total, 2) AS raw,
                   row_number() OVER (ORDER BY q DESC, ib) AS rn
              FROM legs
        ),
        adj AS (
            SELECT c.*, (round(v_process, 2) - SUM(c.raw) OVER ()) AS rem FROM calc c
        )
        INSERT INTO batch_processing_cost_allocations
            (run_id, inbound_batch_id, amount_base, basis_qty, basis_total_qty)
        SELECT p_run_id, ib, raw + CASE WHEN rn = 1 THEN rem ELSE 0 END, q, v_sc_basis_total
          FROM adj;
        END IF;

        SELECT jsonb_agg(jsonb_build_object(
                   'inbound_batch_id', a.inbound_batch_id,
                   'amount_base', a.amount_base,
                   'basis_qty', a.basis_qty)
               ORDER BY a.inbound_batch_id)
          INTO v_sc_rows
          FROM batch_processing_cost_allocations a WHERE a.run_id = p_run_id;

        -- ── 分录:借 1200 / 贷 5xxx —— 【重分类,不是新成本】────────────────────
        -- 电费在录入那一刻就已经进了总账(fin_journal_cost_entry:借 5110 / 贷 2200)。
        -- 这一步不新增任何金额,它把已经在 COGS 里的钱拨进存货。
        v_cap_lines := '[]'::jsonb;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
              FROM processing_cost_entries
             WHERE run_id = p_run_id AND deleted_at IS NULL
             GROUP BY cost_type
             ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type),
                    'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type),
                    'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF round(v_process, 2) <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_process > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(round(v_process, 2)),
                'line_memo', 'capitalised onto input batch — state-changing run')) || v_cap_lines;
            v_cap_je := post_journal_entry(CURRENT_DATE, 'Capitalize ' || v_run.code,
                'allocation', p_run_id, v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        -- 【快照】capitalized_by_source 只列各 cost_type,【故意没有 material 一项】——
        -- 材料没有被资本化(它早就在 1200 上了),写进去会让后来的人以为它进过账。
        v_by_source := '{}'::jsonb;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
              FROM processing_cost_entries
             WHERE run_id = p_run_id AND deleted_at IS NULL
             GROUP BY cost_type
        LOOP
            v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
        END LOOP;

        UPDATE processing_runs
        SET material_cost_base   = round(v_material, 2),
            process_cost_base    = round(v_process, 2),
            total_cost_base      = round(v_total, 2),
            allocation_basis     = v_basis,
            allocation_snapshot  = jsonb_build_object(
                'capitalized_by_source', v_by_source,
                'capitalised_component', 'process_only',
                'capitalised_onto', 'input_batches',
                'destination_account', '1200',
                'basis', v_basis,
                'computed_at', now(),
                'inputs_without_price', v_inputs_without_price,
                'allocations', COALESCE(v_sc_rows, '[]'::jsonb)),
            allocated_at         = now(),
            allocated_by         = v_user,
            capitalized_cost_base   = round(v_process, 2),
            capitalization_entry_id = v_cap_entry_id,
            updated_at           = now(),
            updated_by           = v_user
        WHERE id = p_run_id;

        RETURN jsonb_build_object(
            'run_id', p_run_id,
            'basis', v_basis,
            'state_changing', true,
            'material_cost_base', round(v_material, 2),
            'process_cost_base', round(v_process, 2),
            'total_cost_base', round(v_total, 2),
            'capitalized_cost_base', round(v_process, 2),
            'capitalised_onto', COALESCE(v_sc_rows, '[]'::jsonb),
            'inputs_without_price', v_inputs_without_price,
            'outputs', '[]'::jsonb
        );
    END IF;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
        -- METAL-2:分摊【没有交易可以继承指数】—— 一张加工单不是一笔谈定的买卖,
        -- 没有对手方、没有条款,所以它按 pricing_settings 的房屋约定取价。
        -- 【这是默认值在替一条缺席的条款站位,不是"这批成本按某个声明的指数结算了"】。
        -- 快照里一并记下用的是哪个指数,免得日后有人把它读成一条谈定的条款。
        SELECT default_metal_index INTO v_default_index FROM pricing_settings WHERE id;

        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0)
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        LEFT JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;

        -- Metals present (content > 0) on this run with NO usable price row: excluded from
        -- value (they contributed 0 above) and reported in the snapshot as skipped.
        SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
          INTO v_skipped_metals
        FROM (
            SELECT DISTINCT obm.metal AS m
            FROM processing_outputs po
            JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
            WHERE po.run_id = p_run_id AND obm.content_pct > 0
              AND NOT EXISTS (
                  SELECT 1 FROM metal_prices mp
                  WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                    AND mp.price_date <= v_process_date
              )
        ) s;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
        v_skipped_metals := '[]'::jsonb;
    END IF;

    -- FIN-24:差额法的"已记录"侧 —— 在下面的 UPDATE 改写之前,把各产出腿
    -- 当前的 allocated 拍下来。目标 − 已记录 = 应过账的差额(与重估/折旧同形)。
    SELECT COALESCE(jsonb_object_agg(po.output_batch_id::text,
                    COALESCE(po.allocated_cost_base, 0)), '{}'::jsonb)
      INTO v_prior
    FROM processing_outputs po WHERE po.run_id = p_run_id;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0))
                        FROM output_batch_metals obm
                        LEFT JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_base = f.allocated,
            unit_cost_base = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_base
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_base', allocated,
                   'unit_cost_base', unit_cost_base)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    -- FIN-24:by_source = 本次各来源的入账口径(材料 + 逐 cost_type,各 2 位),
    -- 下一次差额跑的"已记录"就从这里读 —— recorded,不再从分录反推。
    v_by_source := jsonb_build_object('material', round(v_material_in, 2));
    IF round(v_material_re, 2) <> 0 THEN
        -- 再加工材料单列一源:首挂贷 1220(解除上游产出),差额与 material 同贷 5000
        v_by_source := v_by_source || jsonb_build_object('material_reprocessed', round(v_material_re, 2));
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_base), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
    LOOP
        v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
    END LOOP;

    v_snapshot := jsonb_build_object(
        'capitalized_by_source', v_by_source,
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        -- METAL-2:用的是哪个指数,以及它【是房屋约定而不是条款】。
        -- 读快照的人必须能分清这两件事:这批成本不是"按 LME 结算"的,
        -- 它是"在没有条款可循时,按当时的房屋约定取了 LME 的价"。
        'price_index', v_default_index,
        'price_index_is_house_default', true,
        'skipped_metals', v_skipped_metals
    );

    -- 9c(FIN-25):不完整成本标记 —— 任何投料无价、或上游产出自己就带着标记,
    --    本单全部产出打上 cost_incomplete。零永不静默,层层传染;上游补分摊后
    --    本单过期(状态视图第三支),重跑即清。
    UPDATE processing_outputs
    SET cost_incomplete = (v_inputs_without_price > 0 OR v_upstream_incomplete)
    WHERE run_id = p_run_id;

    -- FIN-36c:告诉基准触发器"这次基准变动是【跟着重分摊一起发生的】,不是漂移"。
    -- 与年结用 evoltrya.close_ctx 穿过期间锁是同一个惯用法(post_journal_entry)。
    -- 【为什么不靠时间戳判断】now() 是事务时间:同一个事务里两次分摊拿到相同的
    -- allocated_at,任何"看 allocated_at 变没变"的判据都会失效(fixture 就在一个
    -- 事务里跑)。显式的上下文标记不受事务边界影响。
    PERFORM set_config('evoltrya.alloc_ctx', '1', true);

    UPDATE processing_runs
    SET material_cost_base   = round(v_material, 2),
        process_cost_base    = round(v_process, 2),
        total_cost_base      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 标记只覆盖上面那一条 UPDATE:同一事务里【之后】的裸改基准仍算漂移
    PERFORM set_config('evoltrya.alloc_ctx', '', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- 10a.【FIN-24:首挂全额,此后差额 —— 不再全额冲销重挂】
    -- 旧实现重述资本化(1220 按新价整体改写)而已过账 COGS 从不重述:卖掉份额的
    -- 价差留在库存里,卖得越多错得越多;材料价差贷 1200,而 reprice 早把已耗份额
    -- 记进了 5000 —— 两处叠加 = 重复计数 + 1200 变负(实测:100kg@1 全耗、重定价
    -- 到 2、重分摊 → 1220=200 但 5000 多挂 100、1200=−100)。
    -- 差额法(与重估/折旧同形):目标 − 已记录,只过差额,第二次跑为零。
    --   * 每个产出批按【自己】的处置比例拆(Part B:一炉多批、各卖各的):
    --       在库 + 已售未挂COGS → 1220(后者价值仍躺在 1220,10b 随后按新单位成本解除)
    --       已售已挂COGS       → 5000(COGS 补差)
    --       注销/盘亏           → 5200(处置在产出粒度可知,注销总额是运营信号,
    --                              不并进材料成本 —— Tim 的裁定,推翻了与 reprice
    --                              一致性的论证;reprice 在进料粒度分不出注销与
    --                              耗用、整体进 5000 的不精确,另记 known-issues)
    --   * 贷方:材料差额 → 5000(reprice 把已耗价差停在那里;5000 同时是 COGS
    --     科目,已售份额的借方与之同户恰好互抵 —— 这一巧合是本设计的支点);
    --     费用差额 → 各自成本科目(fin_cost_account)。
    --   * 产出批喂回再加工在 schema 上【不可表示】(processing_inputs 只指
    --     inbound_batches)—— 处置只有在库/已售/注销三种。粉线大概率多段加工,
    --     真建了再加工必须先扩这套拆分(known-issues 有账)。
    -- ════════════════════════════════════════════════════════════════════════
    v_rec_total := COALESCE(v_run.capitalized_cost_base, 0);
    IF v_run.capitalization_entry_id IS NOT NULL THEN
        SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
        IF v_cap_status <> 'posted' THEN
            -- 资本化分录被人工冲销:存量"已记录"与总账已分道,差额法的基准不再可信。
            -- 这是【唯一】剩下的红色情形:人工冲销是人做的决定,修复也该是人工分录。
            RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
        END IF;
    END IF;

    IF v_run.capitalization_entry_id IS NULL THEN
        -- ── 首挂:全额资本化(原路径)────────────────────────────────────────
        v_cap_lines := '[]'::jsonb;
        v_cap_total := 0;
        IF round(v_material_in, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_in, 2));
            v_cap_total := v_cap_total + round(v_material_in, 2);
        END IF;
        -- FIN-25:再加工材料 —— 解除的是上游产出的 1220,不是原料的 1200。
        -- 同科目 Dr(资本化进本单产出)/Cr(解除上游)两腿并存,净额即增量。
        IF round(v_material_re, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_re, 2), 'line_memo', 're-processed input relieved');
            v_cap_total := v_cap_total + round(v_material_re, 2);
        END IF;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
            FROM processing_cost_entries
            WHERE run_id = p_run_id AND deleted_at IS NULL
            GROUP BY cost_type
            ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF v_cap_total <> 0 THEN
            v_cap_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1220',
                                   'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                                   'currency', base_currency_code(), 'amount_ccy', abs(v_cap_total))
            ) || v_cap_lines;
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Capitalize ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = v_cap_total,
            capitalization_entry_id = v_cap_entry_id
        WHERE id = p_run_id;
    ELSE
        -- ── 差额路径 ─────────────────────────────────────────────────────────
        -- 已记录的各来源:优先 snapshot(FIN-24 起写入);老单从已过账的资本化
        -- 分录行反推 —— 1200 行 = 材料,5xxx 行按 fin_cost_account 的反向映射。
        v_rec_src := v_run.allocation_snapshot->'capitalized_by_source';
        IF v_rec_src IS NULL THEN
            SELECT COALESCE(jsonb_object_agg(q.src, q.amt), '{}'::jsonb) INTO v_rec_src FROM (
                SELECT CASE a.code
                           WHEN '1200' THEN 'material'
                           WHEN '5100' THEN 'labour'
                           WHEN '5110' THEN 'electricity'
                           WHEN '5120' THEN 'gas'
                           WHEN '5130' THEN 'depreciation'
                           WHEN '5140' THEN 'consumables'
                           WHEN '5150' THEN 'waste_treatment'
                           WHEN '5190' THEN 'other'
                       END AS src,
                       round(SUM(jl.credit) - SUM(jl.debit), 2) AS amt
                FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
                WHERE jl.entry_id = v_run.capitalization_entry_id AND a.code <> '1220'
                GROUP BY a.code) q
            WHERE q.src IS NOT NULL;
        END IF;

        -- 贷方:逐来源差额。材料 → 5000(不是 1200!—— reprice 已把已耗价差记在
        -- 5000,这里把属于未售产出的部分从 5000 拨进 1220,双方不再叠加);
        -- 费用 → 各自成本科目。负差翻借方。
        v_cap_lines := '[]'::jsonb;
        v_cred_total := 0;
        FOR v_ct IN
            SELECT key AS src, (v_by_source->>key)::numeric - COALESCE((v_rec_src->>key)::numeric, 0) AS d
            FROM jsonb_object_keys(v_by_source) AS key
            UNION
            SELECT key, 0 - (v_rec_src->>key)::numeric
            FROM jsonb_object_keys(v_rec_src) AS key
            WHERE v_by_source->>key IS NULL
            ORDER BY 1
        LOOP
            IF v_ct.d <> 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object(
                    'account_code', CASE WHEN v_ct.src IN ('material', 'material_reprocessed') THEN '5000' ELSE fin_cost_account(v_ct.src) END,
                    'side', CASE WHEN v_ct.d > 0 THEN 'credit' ELSE 'debit' END,
                    'currency', base_currency_code(), 'amount_ccy', abs(v_ct.d),
                    'line_memo', 'allocation delta: ' || v_ct.src);
                v_cred_total := v_cred_total + v_ct.d;
            END IF;
        END LOOP;

        -- 借方:逐产出批的差额,按该批自己的处置比例拆
        FOR v_leg IN
            SELECT po.output_batch_id, po.quantity_produced AS qty,
                   po.allocated_cost_base AS new_alloc,
                   COALESCE((v_prior->>po.output_batch_id::text)::numeric, 0) AS old_alloc,
                   ob.remaining_qty,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NOT NULL), 0) AS sold_cogs,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NULL), 0) AS sold_nocogs,
                   -- FIN-25 第四处置:被下游加工消耗的份额 → 5000 停车
                   --(与 reprice 对已耗进料完全同构:下游过期后重跑,其材料差额
                   -- 贷 5000 收回停车 —— 传导靠既有过期旗逐级走,不递归)
                   COALESCE((SELECT SUM(pi2.quantity_consumed) FROM processing_inputs pi2
                             WHERE pi2.output_batch_id = po.output_batch_id), 0) AS consumed_proc
            FROM processing_outputs po
            JOIN output_batches ob ON ob.id = po.output_batch_id
            WHERE po.run_id = p_run_id
        LOOP
            v_delta := round(v_leg.new_alloc - v_leg.old_alloc, 2);
            IF v_delta = 0 OR v_leg.qty = 0 THEN CONTINUE; END IF;
            v_other := GREATEST(0, v_leg.qty - v_leg.remaining_qty - v_leg.sold_cogs - v_leg.sold_nocogs - v_leg.consumed_proc);
            v_l1220 := round(v_delta * (v_leg.remaining_qty + v_leg.sold_nocogs) / v_leg.qty, 2);
            v_l5000 := round(v_delta * (v_leg.sold_cogs + v_leg.consumed_proc) / v_leg.qty, 2);
            -- 5200 取残差,保证三桶之和恰等于该批差额
            v_d1220 := v_d1220 + v_l1220;
            v_d5000 := v_d5000 + v_l5000;
            v_d5200 := v_d5200 + (v_delta - v_l1220 - v_l5000);
        END LOOP;

        -- 强制配平:Σ借(三桶)与 Σ贷(逐来源)各自取整后可差一两分 ——
        -- 差额并进 1220 桶(金额最大、且是"目标状态"侧,与 8+9 步的
        -- largest-share-absorbs 同一习惯)。
        v_deb_total := v_d1220 + v_d5000 + v_d5200;
        v_d1220 := v_d1220 + round(v_cred_total - v_deb_total, 2);

        IF v_d1220 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '1220',
                'side', CASE WHEN v_d1220 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d1220),
                'line_memo', 'in-stock share')) || v_cap_lines;
        END IF;
        IF v_d5000 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5000',
                'side', CASE WHEN v_d5000 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5000),
                'line_memo', 'sold/consumed share — COGS catch-up / re-processing park')) || v_cap_lines;
        END IF;
        IF v_d5200 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5200',
                'side', CASE WHEN v_d5200 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5200),
                'line_memo', 'written-off share')) || v_cap_lines;
        END IF;

        -- 幂等出口:没有任何差额 → 不过账(allocated_at 照常刷新,过期标记消除)
        IF jsonb_array_length(v_cap_lines) > 0 THEN
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Re-allocation delta ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            -- 差额分录记进 snapshot 的留痕数组;capitalization_entry_id 仍指首挂
            v_snapshot := v_snapshot || jsonb_build_object('delta_entry_ids',
                COALESCE(v_run.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)
                    || to_jsonb((v_cap_je->>'entry_id')::text));
            UPDATE processing_runs SET allocation_snapshot = v_snapshot WHERE id = p_run_id;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = round(v_rec_total + v_cred_total, 2)
        WHERE id = p_run_id;
    END IF;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_base,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_base
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_base, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_base', round(v_material, 2),
        'process_cost_base', round(v_process, 2),
        'total_cost_base', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;

-- ═══ db/functions/reverse_expense.sql ═══
-- 冲销一笔开支单。【关于资本性支出,这里有两条规矩,不是一条】
-- * FIN-22(2026-08-06):生出资产卡的那一笔【永不】可冲(EXPENSE_HAS_ASSET)——
--   冲掉它会留下一台无对价的资产。先 dispose_fixed_asset,或走人工分录改正。
-- * EQP-1b-iii(2026-08-21):【追加】进来的那些笔(运费、关税、安装、设备发票)
--   可冲,而且冲销【必须把 cost_base 一起退回去】并当场核对不变量;
--   但资产一旦投用就按名拒(ASSET_IN_SERVICE_COST_LOCKED)。
--
-- ★★【CAPEX-1(2026-08-29)之后,这一条与 record_expense 那一条【不再是同一个铰链】,
--     而这句话原本就写在这里,现在必须改掉:两者不对称,不许合并】★★
--   原文写的是"与 record_expense 拒绝往已投用资产上追加用的是同一个铰链",
--   以及"投用之后,成本冻住"。**两句都不再成立**:
--   record_expense 那一侧已经改成【窄】拒 —— 经一条标了资本化的维修记录就加得上去
--   (政策 4.7),折旧从那个月起往后摊。
--   **而这一侧【一个字没动,而且应当一个字不动】**:
--     · 一次【追加】是一个新事件 —— 已经提过的折旧在当时是对的,往后走就行;
--     · 一次【冲销】断言那笔支出【本不该存在】—— 那是【回溯】的,
--       它要求已经提过的各期重新来过,而 4.7 没有授权任何回溯的东西。
--   所以两边看起来对称,理由完全不同。**把它们合并,或者"顺手也放开这一侧",
--   就是把一次估计变更与一次错误更正当成同一件事。**
--   (同一个不对称,月度例程用负差额封零表达过一次:向上的变化往前摊,
--    向下的变化仍是一次更正、仍走人工分录。)
-- 向下修正一台【已投用】资产的成本今天仍然没有任何路 —— docs/known-issues.md 有记录。

CREATE OR REPLACE FUNCTION public.reverse_expense(p_expense_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        expenses%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_mirror_code text;
    v_je          jsonb;
    -- EQP-1b-iii:追加模式那一笔的成本明细,以及它挂着的那张资产卡
    v_entry       record;
    v_asset       record;
    v_sum         numeric;   -- 未冲销明细之和(推导出来的那一侧)
    v_after       numeric;   -- 退回之后的表头(被维护的那一侧)
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_orig FROM expenses WHERE id = p_expense_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED|%', v_orig.code;
    END IF;
    -- FIN-22:挂着固定资产台账行的资本性支出不许冲销 —— 冲掉它会留下无对价的
    -- 资产(或者说资产背后那笔应付蒸发)。先处置资产,或走人工分录改正。
    IF EXISTS (SELECT 1 FROM fixed_assets fa WHERE fa.expense_id = p_expense_id) THEN
        RAISE EXCEPTION 'EXPENSE_HAS_ASSET|%', v_orig.code;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1b-iii:【追加模式】的资本支出 —— 冲销它必须把成本退回去。
    -- 上面那条 FIN-22 的守卫只认【建卡的那一笔】(fixed_assets.expense_id),
    -- 追加进来的每一笔(运费、关税、安装,以及设备发票本身)都不是任何一张卡的
    -- 出生证,所以一律冲得掉 —— 而分录冲掉了、cost_base 却原样不动。
    -- 实测(EQP-1b-ii 的回滚探针):100,000 → 100,000,明细 2 行 → 2 行。
    -- 总账从此与台账不一致,而【折旧读的是台账】。
    --
    -- 【为什么这里不加一列"这条明细已冲销"】那件事已经记在 expenses.status 上了,
    -- 而 fixed_asset_cost_entries 对 expense_id 是 UNIQUE —— 一条明细对一笔支出,
    -- 所以"这条明细还算不算数"= "它那笔支出冲了没有",一个事实一个地方。
    -- 本仓库对"已冲销"的既有写法正是这样一个 JOIN(ap_open_items 与
    -- apply_prepayment 都是),invoice_lines 那个冗余列是被【部分索引的 WHERE
    -- 引用不了另一张表】逼出来的,这里没有那个约束,也就不该抄那半代价。
    SELECT fce.id AS entry_id, fce.asset_id, fce.amount_base
      INTO v_entry
      FROM fixed_asset_cost_entries fce
     WHERE fce.expense_id = p_expense_id;

    IF FOUND THEN
        SELECT fa.code, fa.in_service_date, fa.status AS asset_status
          INTO v_asset
          FROM fixed_assets fa
         WHERE fa.id = v_entry.asset_id
           FOR UPDATE;

        -- 【与 record_expense 同一个铰链,方向相反】那边拒绝往已投用的资产上
        -- 【加】钱(ASSET_ALREADY_IN_SERVICE),理由是"已经提过的那几期会全错,
        -- 而它们已经过账、可能已经锁进期间"。【减】钱撞的是同一堵墙,所以判据
        -- 用同一句 in_service_date IS NOT NULL —— 一个铰链管两个方向。
        -- 【为什么不改成"提过折旧没有"】那是【第二个、更晚】的事实:一台已投用
        -- 但月结还没跑的资产会因此今天准冲、明天不准,而资产本身什么都没变;
        -- 而且加钱那边照旧拒,两个方向就不对称了。一个可判定的规则,不是两个。
        -- 【码另起一个,不复用 ASSET_ALREADY_IN_SERVICE】动作不同、话也不同:
        -- 那一句讲的是"投用后的追加是一次会计判断",对冲销是答非所问。
        IF v_asset.in_service_date IS NOT NULL THEN
            RAISE EXCEPTION 'ASSET_IN_SERVICE_COST_LOCKED|%|%|%',
                v_orig.code, v_asset.code, v_asset.in_service_date
              USING HINT = '这台资产已经投用,它的成本不能再被冲回 —— 这需要一次财务上的裁定';
        END IF;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个(reversal_date_for;冲销不许早于原分录)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, reversal_date_for(v_orig.journal_entry_id), 'Expense reversal ' || v_orig.code);

    -- 镜像开支单(同形状、status 'posted'、挂冲销分录、不带核销行)。
    -- 镜像行只是冲销的记录凭证,不是新的应付单据 —— ap_open_items 里按
    -- "被别的开支单指为 reversed_by_expense" 排除它。
    v_year := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE document_type_prefix('expense') || '-' || v_year::text || '-%';
    v_mirror_code := document_type_prefix('expense') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 【EQP-1b-iii · D3:employee_id 要抄,purchase_order_line_id 【不要】抄】
    -- 抄 employee_id:PAYEE-1a 加了这一列并放宽了 expenses_counterparty_shape
    -- (unpaid 必须【恰好】挂一个往来对象),但镜像 INSERT 没跟着改 —— 于是冲销
    -- 一张【欠员工】的报销单会撞出一条裸的 CHECK 违例。这是那一列缺席造成的,
    -- 不是别的。
    -- 不抄 purchase_order_line_id:镜像单是【记录凭证】,不是第二张账单。它一带上
    -- 那一列就会立刻重新占住那条采购单行,而"冲销之后行重新可计费"是 EQP-1b-ii
    -- 明文的行为(fixture 105 的 F3③ 钉着它)。那一列的列注释里点名交代过这件事,
    -- 交代的对象就是这一刀 —— 所以这里把两句话并排写下:一列抄,一列不抄。
    -- 【已逐列核对过一遍,不是只看这两列】expenses 共 20 列,镜像显式写 15 列;
    -- 另外 5 列:status(默认 posted,镜像是在册凭证)、reversed_by_expense(NULL,
    -- 镜像自己没被冲)、created_at(now())——三条都是有意的;employee_id 是唯一
    -- 的漏抄;purchase_order_line_id 是唯一有意不抄的。
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          employee_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, CURRENT_DATE, v_orig.account_code,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.payment_status, v_orig.bank_account_code, v_orig.supplier_id,
            v_orig.employee_id,
            v_orig.payee_name,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());

    UPDATE expenses
    SET status = 'reversed', reversed_by_expense = v_mirror_id
    WHERE id = p_expense_id;

    -- ── EQP-1b-iii:把成本退回去,并【当场核对】──────────────────────────────
    -- 顺序要紧:上面那句 UPDATE 已经把原单置为 reversed,所以下面那个求和
    -- 【天然排除】了它 —— 判据读的是"未冲销明细之和",不是"减掉一笔之后应该是多少"。
    IF v_entry.entry_id IS NOT NULL THEN
        UPDATE fixed_assets
           SET cost_base = cost_base - v_entry.amount_base
         WHERE id = v_entry.asset_id
        RETURNING cost_base INTO v_after;

        -- 【两侧能不能分开动?能 —— 所以这是一条真检查,不是装饰】
        -- 左边是被 record_expense 逐笔累加维护的表头(一个缓存);
        -- 右边是从明细现算的和。两者由不同的代码路径产生,drift 是可能的,
        -- 而这正是 OPS-17 对 ties/balanced 那类自检提的那个问题:
        -- "要怎样它们才会不相等?" —— 这里答得出来。
        SELECT COALESCE(SUM(fce.amount_base), 0) INTO v_sum
          FROM fixed_asset_cost_entries fce
          JOIN expenses e ON e.id = fce.expense_id
         WHERE fce.asset_id = v_entry.asset_id
           AND e.status = 'posted';

        IF v_after <> v_sum THEN
            RAISE EXCEPTION 'ASSET_COST_LEDGER_DIVERGED|%|%|%',
                v_asset.code, v_after, v_sum;
        END IF;
    END IF;

    -- 【两条 CHECK 都不会被这次减法撞到,而这是可以证明的,不是碰巧】
    --   fixed_assets_cost_base_check      cost_base > 0
    --   fixed_assets_residual_below_cost  residual_base < cost_base
    -- 能被冲销的只有【追加】那些笔(建卡那一笔由 EXPENSE_HAS_ASSET 拦着),
    -- 而 residual_base 只在建卡时写入一次(全库只有 record_expense 写它),
    -- 当时就校验过 residual < 建卡金额。把追加全部冲光,表头也还剩建卡金额,
    -- 于是 cost_base ≥ 建卡金额 > residual_base ≥ 0,两条恒成立。
    RETURN jsonb_build_object(
        'reversal_expense_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code',
        'asset_id', v_entry.asset_id,
        'asset_cost_base_after', v_after
    );
END;
$function$;

-- ═══ db/functions/reverse_payment_internal.sql ═══
-- db/functions/reverse_payment_internal.sql
-- PAY-REQ-1(2026-09-23):reverse_payment 的函数体搬到这里,拿掉了权限检查,
-- 并补上镜像行漏抄的 employee_id。下面是它原来的抬头,照录:
--
-- SOD-1(2026-08-24):这支函数现在【声明】自己在冲销。
-- guard_payment_sod 会拦住"建收款人的人付款给该收款人",而冲销的镜像行
-- direction/counterparty 与原单相同,会走到那道闸上。冲销是把钱【收回来】的
-- 更正动作 —— 拦住它只会把一笔记错的付款锁死在账上,而且拦不住任何舞弊。
-- 所以由调用方显式声明,不由守卫去猜(po_status_ctx / close_ctx / alloc_ctx 同一惯用法)。
-- 【用完立刻清掉】set_config(..., true) 是【事务】局部,不是语句局部 ——
-- 只设不清,同一事务里后面任何一笔直连 INSERT 都会畅通无阻(APR-2c fu2 实测过)。
-- fixture 127 的 B5 臂把"立起来"与"落下去"一起断言。

CREATE OR REPLACE FUNCTION public.reverse_payment_internal(p_payment_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        payments%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_mirror_code text;
    v_je          jsonb;
BEGIN
    -- ★ PAY-REQ-1:这里【没有】权限检查 —— 内层引擎,EXECUTE 已从 authenticated 收回。
    --   唯一的外门是 pay_payment_request(finance.edit,且只执行一张已批准的冲销申请);
    --   payment_request_dry_run 在提交与批准时照同一套规矩核一遍再回滚。
    SELECT * INTO v_orig FROM payments WHERE id = p_payment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND|%', p_payment_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_payment IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个(reversal_date_for;冲销不许早于原分录)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, reversal_date_for(v_orig.journal_entry_id), 'Payment reversal ' || v_orig.code);

    -- 镜像收付款单(现金退回),挂冲销分录,不带核销行
    v_mirror_code := fin_next_payment_code(CASE WHEN v_orig.direction = 'in' THEN document_type_prefix('payment_receipt') ELSE document_type_prefix('payment_out') END, CURRENT_DATE);

    -- SOD-1:告诉 guard_payment_sod 这是一次【冲销】,不是一次付款。
    PERFORM set_config('evoltrya.payment_reversal_ctx', '1', true);
    -- ★ PAY-REQ-1:镜像行此前【漏抄 employee_id】—— payments 的形状 CHECK 要求
    --   付给员工的那一行恰好带着它,于是冲销一笔员工付款会撞 CHECK 失败
    --   (PAY-REQ-1 grilling 读代码发现;从此每一次冲销都走申请,这条路第一次真的会被走到)。
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          employee_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, v_orig.direction, v_orig.counterparty_type,
            v_orig.customer_id, v_orig.supplier_id, v_orig.employee_id,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.bank_account_code, CURRENT_DATE,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());
    -- 【立刻清掉】—— 事务局部,不清就一直开着。
    PERFORM set_config('evoltrya.payment_reversal_ctx', '', true);

    UPDATE payments
    SET status = 'reversed', reversed_by_payment = v_mirror_id
    WHERE id = p_payment_id;

    RETURN jsonb_build_object(
        'reversal_payment_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code'
    );
END;
$function$;

-- ═══ db/functions/reverse_freight_document.sql ═══
CREATE OR REPLACE FUNCTION public.reverse_freight_document(p_freight_document_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_orig freight_documents%ROWTYPE;
    v_settled numeric;
    v_je jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- 【理由必填,拒绝按名】—— AUDEL 家族那一条。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'FREIGHT_REVERSAL_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM freight_documents WHERE id = p_freight_document_id), '?')
          USING HINT = '没有理由的冲销,事后没人答得出为什么';
    END IF;

    SELECT * INTO v_orig FROM freight_documents
     WHERE id = p_freight_document_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FREIGHT_NOT_FOUND|%', COALESCE(p_freight_document_id::text, '?');
    END IF;
    IF v_orig.status <> 'posted' THEN
        RAISE EXCEPTION 'FREIGHT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 【已被结清的单据不许冲销】—— 冲掉它,账龄里那一行消失,而指向它的核销行
    -- 原样留着:一笔真的付过的钱,从此挂在一张"不欠任何人"的单据上。
    -- 与 FIN-22 的 EXPENSE_HAS_ASSET 同一条:先把下游拆掉,或走人工分录改正。
    SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
      FROM payment_allocations pa
      JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
     WHERE pa.freight_document_id = p_freight_document_id;
    IF v_settled > 0 THEN
        RAISE EXCEPTION 'FREIGHT_HAS_SETTLEMENT|%|%', v_orig.code, v_settled
          USING HINT = '这张运费单已经被付过款 —— 先冲掉那笔付款,再冲销单据';
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)。
    -- 【镜像的是原分录本身】,所以两个方向自动各自对称:进料侧冲掉 1200/5000,
    -- 出境侧冲掉 6300 —— 这个函数一个科目码都不需要知道。
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个(reversal_date_for;冲销不许早于原分录)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, reversal_date_for(v_orig.journal_entry_id),
        'Freight reversal ' || v_orig.code);

    -- 【状态只能从这里改】—— 守卫认这个标记,PostgREST 够不着它。
    PERFORM set_config('evoltrya.freight_reverse_ctx', '1', true);
    UPDATE freight_documents
       SET status = 'reversed', reversed_at = now(), reversed_by = v_user,
           reversal_reason = btrim(p_reason),
           reversal_entry_id = (v_je->>'reversal_id')::uuid,
           updated_by = v_user
     WHERE id = p_freight_document_id;
    PERFORM set_config('evoltrya.freight_reverse_ctx', '', true);   -- 用毕即清

    RETURN jsonb_build_object(
        'freight_document_id', p_freight_document_id, 'code', v_orig.code,
        'direction', v_orig.direction, 'status', 'reversed',
        'reversed_by', v_user, 'reason', btrim(p_reason),
        'reversal_entry_id', v_je->>'reversal_id', 'journal_code', v_je->>'code');
END;
$function$;

-- ═══ db/functions/rollback_processing_run.sql ═══
CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_run_deleted_at timestamptz;
    v_process_date date;     -- FIN-32:还原流水的业务日 = 原加工单的加工日
    v_bad_output record;
    v_input record;
    v_old_remaining numeric;
    v_new_remaining numeric;
    v_quantity numeric;
    v_cap uuid;             -- 首挂的资本化分录
    v_delta_id uuid;        -- PROC-COST-2:重分摊的差额分录,逐张
    v_code text;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- AUDEL-1b:【理由必填】回滚一张加工单是一次很大的操作动作 —— 它软删产出批、
    -- 还原投入、写一整串冲销流水 —— 而此前它【一个 why 都不记】。
    -- 校验放在任何写之前:被拒 = 什么都没发生。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ROLLBACK_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM processing_runs WHERE id = p_run_id), '?');
    END IF;
    -- 1. 锁定加工单，校验存在且未删除
    SELECT process_date INTO v_process_date FROM processing_runs WHERE id = p_run_id;
    SELECT deleted_at INTO v_run_deleted_at
    FROM processing_runs
    WHERE id = p_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;

    IF v_run_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_ALREADY_DELETED';
    END IF;

    -- 标记本次为回滚上下文,供产出批次软删触发器发出 reversal_void。
    PERFORM set_config('evoltrya.movement_ctx', 'reversal:' || p_run_id::text, true);

    -- 2. 安全检查：任何一个产出批次动过就拒绝
    SELECT ob.code, ob.state, ob.quantity, ob.remaining_qty
    INTO v_bad_output
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id
      AND ob.deleted_at IS NULL
      AND (ob.state <> '库存中' OR ob.remaining_qty <> ob.quantity)
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'OUTPUT_CONSUMED|%|%|%|%',
            v_bad_output.code, v_bad_output.state, v_bad_output.remaining_qty, v_bad_output.quantity;
    END IF;

    -- 3. 还原进料：加回 remaining_qty，重判 stage，记 reversal_restore 流水。
    --    FIN-25:产出批投料同样还原(不碰 state —— 那是销售状态)。
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        IF v_input.inbound_batch_id IS NOT NULL THEN
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM inbound_batches
            WHERE id = v_input.inbound_batch_id
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 进料批次已被删，跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.inbound_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:还原不是物理事件,是在更正一次记错的加工单 —— 业务日取
                -- 【原加工单的 process_date】,于是消耗与还原在同一天对消,
                -- 中间那几天的库存历史不会凭空少掉一批实际还在的货。
                --
                -- 【IOD-1:逐行镜像原始流水,不按规则重新分配】投料现在可能跨几个
                -- 库位桶写出多行;还原必须把货放回【它原来所在的那些桶】,而不是
                -- 按 drain 的顺序倒着来一遍 —— 那两者在一般情形下并不相等,
                -- 差额会安静地把库存挪到别的库位上。所以这里读原始的
                -- processing_consume 行,逐行取反。
                PERFORM mirror_consume_restore(p_run_id, v_input.inbound_batch_id, NULL,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        ELSE
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM output_batches
            WHERE id = v_input.output_batch_id AND deleted_at IS NULL
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 上游产出批已被删（如其自身加工单已冲销），跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.output_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:同上 —— 产出批投料的还原(FIN-25 那条边)业务日一样取原加工日
                PERFORM mirror_consume_restore(p_run_id, NULL, v_input.output_batch_id,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        END IF;
    END LOOP;

    -- 4. 软删这张单生成的产出批次(void 流水 + 归零由 BEFORE UPDATE 触发器处理)
    -- AUDEL-1b:软删要走门 —— 标记 + deleted_by + delete_reason,否则
    -- guard_soft_delete_provenance 会按名拒。产出批的删除理由【就是这次回滚的
    -- 理由】:它们不是被单独注销的,是被这次回滚带走的。
    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE output_batches
    SET deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id IN (
        SELECT output_batch_id FROM processing_outputs WHERE run_id = p_run_id
    )
    AND deleted_at IS NULL;

    -- 5. 软删加工单本身（腿表保留作审计）
    UPDATE processing_runs
    SET status = 'reversed',
        deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);   -- 用毕即清(同 movement_ctx)

    -- ════════════════════════════════════════════════════════════════════════
    -- 【解除资本化 —— 台账与分录在同一个地方一起解除】(PROC-COST-1 立,
    --   PROC-COST-2 把工序种类的判断【拿掉】)
    --
    -- 台账那一半由基函数按本单的 deleted_at 自动排除(形状免费提供的);
    -- 分录那一半必须显式冲销 —— 两半都在这里发生,所以它们永远不会各说各话。
    -- 少做任何一半:要么成本留在存货上而单已经没了(账挂在一张不存在的单上),
    -- 要么台账清了而存货虚高。
    --
    -- ★【PROC-COST-2:这里原来有一句 `IF v_sc_kind`,只管状态改变型】★
    -- 于是**转化型加工单回滚之后,它的资本化分录(借 1220 / 贷 1200 / 贷 5xxx)
    -- 原样立着** —— 产出批已经被软删,1220 上却还挂着它的成本。
    -- 那个判断本刀【拿掉】:两种工序共用同一段代码,不是照着它再写一份。
    --   * 状态改变型:冲销 借 1200 / 贷 5xxx,成本从原料批上退回费用;
    --   * 转化型:    冲销 借 1220 / 贷 1200 / 贷 5xxx —— 1220 上的产出成本
    --     被拿掉,而投料的 1200 同时被还回来,与第 3 步还原 remaining_qty 同向。
    --
    -- 【产出批软删【不再】另外入账,这两件事必须一起读】注销触发器在
    -- reversal 上下文里不写分录 —— 因为解除 1220 的是这里冲销的这张分录。
    -- 两处都做就是重复计数。
    --
    -- ★【差额分录也要冲 —— 只补首挂的话,一张被重分摊过的单仍然错】★
    -- 转化型重分摊走的是差额路径:capitalization_entry_id 仍指首挂,新的差额
    -- 分录记在 allocation_snapshot->'delta_entry_ids' 里。只冲首挂,差额留在
    -- 1220 上,而这张单看起来已经修好了 —— 那是最坏的一种半修。
    -- (状态改变型不会有差额分录:它走的是冲旧挂新,capitalization_entry_id
    --  永远指着唯一活着的那一张。这个循环对它自然空转,不需要分支。)
    --
    -- 【第四个候选:sales_records 上的 COGS 分录 —— 不需要任何处置】
    -- 第 2 步的 OUTPUT_CONSUMED 闸在任何产出动过之后就拒绝回滚,而一次销售
    -- 必然动 remaining_qty。**够不到的东西不需要修,但需要被点名**,
    -- 否则下一个读到这里的人会把这条推理重做一遍。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT code, capitalization_entry_id INTO v_code, v_cap
      FROM processing_runs WHERE id = p_run_id;

    IF v_cap IS NOT NULL
       AND (SELECT status FROM journal_entries WHERE id = v_cap) = 'posted' THEN
        PERFORM reverse_journal_entry_internal(v_cap, reversal_date_for(v_cap),  -- AP-RECON-1 Batch B
            'Rollback ' || COALESCE(v_code, '?'));
    END IF;

    FOR v_delta_id IN
        SELECT (jsonb_array_elements_text(
                    COALESCE(pr.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)))::uuid
          FROM processing_runs pr WHERE pr.id = p_run_id
    LOOP
        IF (SELECT status FROM journal_entries WHERE id = v_delta_id) = 'posted' THEN
            PERFORM reverse_journal_entry_internal(v_delta_id, reversal_date_for(v_delta_id),  -- AP-RECON-1 Batch B
                'Rollback ' || COALESCE(v_code, '?'));
        END IF;
    END LOOP;

    UPDATE processing_runs
       SET capitalization_entry_id = NULL, capitalized_cost_base = 0
     WHERE id = p_run_id;

    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)

    -- ── COD-1:冲销之后,这几票货不再是"加工完"的 ────────────────────────
    -- 【已签发的证书在这里作废,而且没有替代品】—— 冲销说的是那次加工没发生。
    -- 不做这一步,供应商手里那张纸就还在说着一件系统已经不再相信的事,
    -- 而没有任何东西会提醒任何人。将来重新加工到完,那时会成立一张新的证书。
    FOR v_input IN
        SELECT DISTINCT pi.inbound_batch_id FROM processing_inputs pi
         WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL
    LOOP
        PERFORM refresh_cod_for_batch(v_input.inbound_batch_id);
    END LOOP;
END;
$function$;

-- ═══ db/functions/unpost_payroll_period.sql ═══
CREATE OR REPLACE FUNCTION public.unpost_payroll_period(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_p    record;
    v_je   jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;
    -- FIN-4:已有工资行付了钱,冲销周期会让那些结算变孤儿 —— 拒绝,先冲付款
    IF EXISTS (SELECT 1 FROM payroll_lines
               WHERE payroll_period_id = p_id AND paid_at IS NOT NULL) THEN
        RAISE EXCEPTION 'PAYROLL_LINES_PAID|%', v_p.code;
    END IF;
    -- FIN-5:CPF / 代扣款已汇出的期间同理 —— 先冲那笔汇款
    IF v_p.cpf_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_CPF_PAID|%', v_p.code;
    END IF;
    IF v_p.deductions_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_DEDUCTIONS_PAID|%', v_p.code;
    END IF;

    -- 冲销分录;原分录留在账上并被标记为已冲销 —— 不删账
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个。薪资按【发薪日】过账,而发薪日
    -- 可以晚于今天(28 号过账、月末发薪);撤回一张还没到发薪日的薪资是正当的更正,
    -- 所以冲销落在发薪日,而不是被 REVERSAL_BEFORE_ORIGINAL 拒掉。
    v_je := reverse_journal_entry_internal(v_p.journal_entry_id, reversal_date_for(v_p.journal_entry_id), 'Payroll reversal ' || v_p.code);

    UPDATE payroll_periods
    SET status = 'draft',
        journal_entry_id = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unposted] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_id,
        'code', v_p.code,
        'status', 'draft',
        'reversal_journal_code', v_je->>'code'
    );
END;
$function$;

-- ═══ 线上残留:7 行(Tim AP-RECON-1 Q9 / Batch B Q1)═══
-- 【只在迁移里,不在镜像里】这些行描述的是测试库上切换之前的历史,生产全新重建时那段历史不存在。
-- 金额是它对"清单 − 总账"的贡献,取自 AP-RECON-0 §R 与 AP-RECON-1 §1 的逐单据表(线上 2026-09-24 以
-- tim@ 读视图、postgres 读基表复量:应付 45,172.96、应收 20,350.00;加上重估与挂账两行,两边未解释都是 0.00)。
-- IN-2026-0029 / OUT-2026-0001 / RCPT-2026-0001 不在这里:它们整个由重估行与挂账行解释(Batch B Q1)。
INSERT INTO public.list_ledger_residue (side, doc_code, amount_base, residue_class, reason, known_wrong_ref) VALUES
    ('ap', 'IN-2026-0001', 7104.00, 'priced_before_payable_posting', '2026-07-05 首次定价(应付过账之前,从未过账);07-06 改价时 cut 2a 只过了价差且一分钟后被冲销 —— 整批从来没有进过 2000。', 'docs/known-wrong-until-cutover.md: IN-2026-0001'),
    ('ap', 'IN-2026-0003', 30000.00, 'priced_before_payable_posting', '同 IN-2026-0001 的形状:首价未过账,改价只过价差且被冲销 —— 整批从来没有进过 2000。', 'docs/known-wrong-until-cutover.md: IN-2026-0003'),
    ('ap', 'IN-2026-0011', 2100.00, 'priced_before_payable_posting', '2026-07-05 定价,早于 07-06 cut 2a 开始过应付 —— 从来没有 purchase 分录。', 'docs/known-wrong-until-cutover.md: IN-2026-0011'),
    ('ap', 'IN-2026-0012', 10000.00, 'priced_before_payable_posting', '2026-07-05 定价,早于 07-06 cut 2a 开始过应付 —— 从来没有 purchase 分录。', 'docs/known-wrong-until-cutover.md: IN-2026-0012'),
    ('ap', 'IN-2026-0154', -4032.00, 'deleted_while_owing', '已计价、还欠着钱就被注销(2026-08-06):注销只写了 writeoff,计价分录记下的应付留在 2000 上,而每个应付读者都过滤已注销的批次。这条路 AP-RECON-1 Batch A 已经堵上(INBOUND_HAS_OPEN_PAYABLE)。', 'docs/known-wrong-until-cutover.md: IN-2026-0154'),
    ('ap', 'EXP-2026-0001', 0.96, 'fin2_backfill_units', 'FIN-2 回填 allocated_ccy 时写入的是本位币数(USD 3.70 读成 SGD 3.70),清单算出 0.96 的残额;它那条 USD 付款行的 0.94 重估由重估那一行解释,不在这里。', 'docs/known-wrong-until-cutover.md: EXP-2026-0001'),
    ('ar', 'OUT-2026-0007', 20350.00, 'sold_before_sales_posting', '2026-07-05 卖出(SGD 27,500 × 0.74),早于 07-06 开始过销售分录 —— 1100 上一张分录都没有。', 'docs/known-wrong-until-cutover.md: PROC-2026-0003 / OUT-2026-0007(第 13 行)');

-- 三支新函数:PostgreSQL 把 EXECUTE 授给 PUBLIC,apply_migration.sh 会在本事务里重放
-- zzz_function_grants.sql(收回 PUBLIC/anon、授 authenticated)。
COMMIT;
