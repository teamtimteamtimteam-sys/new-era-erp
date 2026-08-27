-- db/migrations/2026-08-27-statement1-customer-statements-of-account.sql
-- STATEMENT-1:客户对账单 —— 签发机制的【第八个成员】,以及它唯一真正新的那一半。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【七个先例,一个新问题】现有七张签发档(qt/so/po/invoice/cn/shipment/
-- traceability)形状逐字相同:`<subject>_id, version, file_path, sha256,
-- issued_at, issued_by`,而且【七张都在用】(2/2/3/4/1/3/1 行)。表、RLS、镜像、
-- record_*_issue、桶、双语拒绝 —— 这六样是机械的,抄第八遍。
--
-- ★【真正新的那一件】★ 前七个签发的都是【一行记录】的文档:一张采购单、一张发票。
-- **对账单的正文是一个【区间】** —— 一个客户在一段时间里的期初、发生、期末。
-- 所以它需要一样别的七个都不需要的东西:**把算出来的东西冻住**。
--
-- 【冻结:抄的是哪一条先例】(Tim 2026-08-27 裁定:数字与字节【都】冻)
--   · **字节** 走签发档那一族(PDF 进桶 + sha256 + 版本),与前七个一字不差;
--   · **数字** 走 `bank_reconciliations` 那一条 —— 一次事件一行、抄下来、不可改,
--     要更正就【新起一行】并把旧的标 superseded,而不是原地覆盖。
--     那张表的抬头把理由写死了:「我们当时是照着什么对上的」与「今天重算是多少」
--     是两个问题,日后有人问的一定是前一个。`gst_return_boxes`(报出去的那一份)
--     是同一条的第三次。
--   **只冻字节不冻数字**,等于宣称"想知道 5 号发出去的是什么,自己去开 PDF";
--   **只冻数字不冻字节**,等于宣称"寄出去的那份和存下来的那份一定长一样"。
--
-- 【重新签发的两层,各答各的问题】(同一条裁定)
--   · 同一段期间【数字变了】再出一次 → **新的一行 customer_statements**
--     (它确实是另一份文件),旧的落 superseded_at + 理由,不删;
--   · 同一行【重新渲染】 → statement_issues 里的 **v2**。
--   一层答"我们 5 号发出去的是哪一份",另一层答"那一份的第几版"。
--
-- 【口径:结转式(brought-forward),不是未清项式】(同一条裁定)
--   期初 + 发生 − 贷记 − 收款 = 期末。客户能照着对账、能据此争。
--   未清项式便宜得多,但它答不出"你说我欠这么多,凭什么"。
--
-- ★【期初与期末【不自己算】—— 读 AGING-1 那支函数】★
--   `ar_aging_asof(D)` 已经把"截至 D 这个客户还欠多少"算清楚了,而且那支函数的
--   四层"截至"(视图接不了参数 / 结清按付款日 / 单据在那天在不在 / 金额在那天是多少)
--   由 db/fixtures/135 逐条钉住。**对账单再算一遍,就是同一个数的第二份实现** ——
--   而这个数正是客户可能拿来跟你对的那个数。
--
-- 【于是勾稽是【两份独立推导】,不是自己跟自己比】(OPS-17 那一条)
--   期初/期末来自 ar_aging_asof;发生/贷记/收款来自基表。两边【能够】不相等,
--   所以那条等式是一次真的检查 —— 不成立就 **STATEMENT_DOES_NOT_TIE 按名拒**,
--   不是记一个 flag。一份对不上的对账单不该寄给客户。
--
-- 【多币种:实测每一个客户都是】ST Engineering 与 Test Customer 都同时有 SGD 与
-- USD 单据;Test Customer-2 是 **SGD 的发票、USD 的收款**。所以:
-- **每个币种各自成段、各自合计,另给一个明标为折算的本位币总额。**
-- 把 USD 与 SGD 直接加成一个数而不说,正是 formatMoneyBare 与币种字面量检查
-- 存在的那个毛病。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1 · customer_statements —— 冻下来的那一行(形状取自 bank_reconciliations)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.customer_statements (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL UNIQUE,
    customer_id       uuid NOT NULL REFERENCES public.customers (id) ON DELETE RESTRICT,
    period_start      date NOT NULL,
    period_end        date NOT NULL,
    base_currency     text NOT NULL REFERENCES public.currencies (code),
    -- 本位币的五个数。等式在签发那一刻就已经验过(对不上按名拒),
    -- 所以这里存的是【当时确实成立的那五个数】。
    opening_base      numeric NOT NULL,
    charges_base      numeric NOT NULL,
    credits_base      numeric NOT NULL,
    receipts_base     numeric NOT NULL,
    closing_base      numeric NOT NULL,
    -- 【明细也冻】(Tim 2026-08-27)客户争的是行,不是合计。
    -- 只冻合计,屏幕就只能说"我们当时告诉你是 24,000",而说不出是哪几张单据 ——
    -- 而"再推导一遍"正是冻结要避免的那件事。
    lines             jsonb NOT NULL,
    -- 每个币种一段:{currency, opening, charges, credits, receipts, closing}
    by_currency       jsonb NOT NULL,
    -- 期末账龄四档(读 ar_aging_asof 的 buckets,不自己分档)
    buckets           jsonb NOT NULL,
    issued_at         timestamptz NOT NULL DEFAULT now(),
    issued_by         uuid,
    -- 【更正 = 新起一行,旧的标掉,不删】与 bank_reconciliations 逐字同源。
    superseded_at     timestamptz,
    superseded_by     uuid REFERENCES public.customer_statements (id),
    superseded_reason text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT customer_statements_period_shape CHECK (period_end >= period_start),
    CONSTRAINT customer_statements_supersede_shape
        CHECK ((superseded_at IS NULL) = (superseded_by IS NULL))
);

COMMENT ON TABLE public.customer_statements IS
    'STATEMENT-1:一份对账单 = 一行,而那一行是【抄下来的】。签发那一刻把期初/发生/贷记/收款/期末五个本位币数、每币种分段、期末账龄四档、以及【明细行】一起冻在这里;此后底下的收款与贷项凭证再动,这一行一个字不动 —— 与 bank_reconciliations、gst_return_boxes 同一条规矩,理由也是同一个:「我们当时寄出去的是什么」与「今天重算是多少」是两个问题,日后客户问的一定是前一个。【为什么是一行一次事件,不是可改的列】同一段期间数字变了再出一次,是【另一份文件】,不是把上一份改掉:新起一行,旧行落 superseded_at + 理由。写入只走 issue_customer_statement(SECURITY DEFINER),所以这里只开 SELECT。PDF 的版本在 statement_issues 里另算一层。';

CREATE INDEX idx_customer_statements_customer
    ON public.customer_statements (customer_id, period_end DESC);

ALTER TABLE public.customer_statements ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是 issue_customer_statement
-- (属主权限)—— 与 bank_reconciliations、approval_log、七张签发档同一条:
-- 一份档案不该有第二个写法。
CREATE POLICY "customer_statements select by permission" ON public.customer_statements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- 2 · statement_issues —— 签发档的第八个成员,形状一个字没改
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.statement_issues (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    statement_id uuid NOT NULL REFERENCES public.customer_statements (id),
    version      integer NOT NULL CHECK (version >= 1),
    file_path    text NOT NULL,
    sha256       text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at    timestamptz NOT NULL DEFAULT now(),
    issued_by    uuid,
    UNIQUE (statement_id, version)
);

COMMENT ON TABLE public.statement_issues IS
    'STATEMENT-1:对账单的签发档 —— 签发机制的【第八个】成员,形状逐字取自 cn_issues / so_issues / po_issues(一个字没改)。谁、何时、第几版、哪一份对账单、字节摘要。【没有"已发送"标志】—— 系统不知道对方收没收到,而一个永远为 false 的标志会被读成"没发出去"。唯一写入口 record_statement_issue();重新渲染 = 新的一版,绝不覆盖旧行。【注意它与 customer_statements 分两层】这一层版本化的是【同一份对账单的 PDF】;数字变了要出的是【另一份对账单】(新的 customer_statements 行),不是这里的 v2。';

CREATE INDEX idx_statement_issues_statement
    ON public.statement_issues (statement_id, version DESC);

CREATE TRIGGER trg_statement_issues_append_only
    BEFORE UPDATE OR DELETE ON public.statement_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_append_only();

ALTER TABLE public.statement_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "statement_issues select by permission" ON public.statement_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- 3 · 取号器
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_statement_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 自己的一把锁(与 next_credit_note_code / next_quote_code 同一惯用法):
    -- 共用一把会烧掉别人的号,而无缝的意思正是号码之间没有洞。
    PERFORM pg_advisory_xact_lock(hashtext('statement_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM customer_statements
     WHERE code LIKE 'STMT-' || v_year::text || '-%';
    RETURN 'STMT-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

COMMENT ON FUNCTION public.next_statement_code(date) IS
    'STATEMENT-1:对账单取号器。自己一把 advisory lock,与贷项凭证/报价单各自连号 —— 共用一把会烧掉别人的号。无调用者检查,靠的就是调不到:唯一调用方 issue_customer_statement(DEFINER,module.finance.edit)。';

-- ───────────────────────────────────────────────────────────────────────────
-- 4 · 算一份对账单 —— 【预览与签发共读这一支】
-- ───────────────────────────────────────────────────────────────────────────
-- 【为什么是一支共享函数,不是页面自己拼】AGENTS.md 那条:预览一次过账的屏幕
-- 【要问数据库它会是什么】,不许在 TypeScript 里重写一遍规则。这个仓库为这个
-- 形状付过四次账(化验预览、假期公式、重估预览、/finance/payments)。
-- 所以:一份实现,两个调用方 —— 预览读它,签发也读它然后把结果冻下来。
--
-- 【期初/期末不自己算】读 ar_aging_asof(见抬头)。它返回全部客户,这里按
-- customer_id 过滤 —— 那支函数已经把"截至某天"的四层都处理好了。
CREATE OR REPLACE FUNCTION public.customer_statement_data(
    p_customer_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
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
                 AND sr.sale_date BETWEEN p_from AND p_to), 2), 0)
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
$function$;

COMMENT ON FUNCTION public.customer_statement_data(uuid, date, date) IS
    'STATEMENT-1:算一份对账单 ——【预览与签发共读这一支】(AGENTS.md「预览要问数据库」那一条:一份实现,两个调用方)。结转式:期初 + 发生 − 贷记 − 收款 = 期末。**期初与期末读 ar_aging_asof,不自己算** —— 那支函数的四层「截至」由 db/fixtures/135 钉住,再算一遍就是同一个数的第二份实现,而这个数正是客户会拿来跟你对的那个。发生/贷记/收款来自基表,所以那条等式是【两份独立推导】之间的检查(OPS-17 那一条:两边要能够分开),对不上由 issue_customer_statement 按名拒。收款的「在期末那天站着没有」与 ar_aging_asof 同源:期末之后才冲销的收款,在期末是算数的。no_movement 是一个有名字的状态,不是一张空表。';

-- ───────────────────────────────────────────────────────────────────────────
-- 5 · 签发一份对账单 —— 把算出来的东西【冻下来】
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.issue_customer_statement(
    p_customer_id uuid, p_from date, p_to date, p_supersede_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d      jsonb;
    v_id     uuid := gen_random_uuid();
    v_code   text;
    v_prev   uuid;
    v_prevcd text;
BEGIN
    -- 签发是一个【动作】,不是一次阅读:比 customer_statement_data 的门更紧一档。
    PERFORM require_permission('module.finance.edit');

    -- 【算的那一支就是预览读的那一支】—— 不在这里重写一遍
    v_d := customer_statement_data(p_customer_id, p_from, p_to);

    -- ★【对不上就不寄】★ 期初/期末来自 ar_aging_asof,发生/贷记/收款来自基表 ——
    -- 两份推导【能够】分开,所以这条等式是一次真的检查,不是装饰(OPS-17)。
    -- 对不上说明是【我们这边】的算术出了问题,而不是客户欠得不对;
    -- 一份自己都对不上的对账单寄出去,是把一个内部错误变成一场客户争议。
    IF (v_d->>'ties')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'STATEMENT_DOES_NOT_TIE|%|%|%',
            (v_d->>'customer_code'), (v_d->>'tie_difference'), (v_d->>'closing_base');
    END IF;

    -- 【同一段期间已经出过 → 新起一行,把旧的标掉】(不是改旧的那一行)
    -- 数字既然变了,那就是【另一份文件】;而更正必须是一个新事件。
    SELECT id, code INTO v_prev, v_prevcd
      FROM customer_statements
     WHERE customer_id = p_customer_id
       AND period_start = p_from AND period_end = p_to
       AND superseded_at IS NULL
     ORDER BY issued_at DESC LIMIT 1;

    IF FOUND AND COALESCE(btrim(p_supersede_reason), '') = '' THEN
        RAISE EXCEPTION 'STATEMENT_SUPERSEDE_REASON_REQUIRED|%|%', v_prevcd, (v_d->>'customer_code');
    END IF;

    v_code := next_statement_code(CURRENT_DATE);

    INSERT INTO customer_statements
        (id, code, customer_id, period_start, period_end, base_currency,
         opening_base, charges_base, credits_base, receipts_base, closing_base,
         lines, by_currency, buckets, issued_by)
    VALUES (v_id, v_code, p_customer_id, p_from, p_to, (v_d->>'base_currency'),
            (v_d->>'opening_base')::numeric, (v_d->>'charges_base')::numeric,
            (v_d->>'credits_base')::numeric, (v_d->>'receipts_base')::numeric,
            (v_d->>'closing_base')::numeric,
            v_d->'lines', v_d->'by_currency', v_d->'buckets', auth.uid());

    IF v_prev IS NOT NULL THEN
        UPDATE customer_statements
           SET superseded_at = now(), superseded_by = v_id,
               superseded_reason = btrim(p_supersede_reason)
         WHERE id = v_prev;
    END IF;

    RETURN jsonb_build_object(
        'statement_id', v_id, 'code', v_code,
        'customer_code', (v_d->>'customer_code'),
        'period_start', p_from, 'period_end', p_to,
        'closing_base', (v_d->>'closing_base')::numeric,
        'no_movement', (v_d->>'no_movement')::boolean,
        'superseded', v_prevcd);
END;
$function$;

COMMENT ON FUNCTION public.issue_customer_statement(uuid, date, date, text) IS
    'STATEMENT-1:把一份对账单【冻下来】。数字由 customer_statement_data 算(预览读的是同一支),然后原样存进 customer_statements ——此后底下再动,这一行不动。★对不上就不寄★:期初/期末来自 ar_aging_asof、发生/贷记/收款来自基表,两份推导能够分开,所以那条等式是真的检查;不成立按名拒 STATEMENT_DOES_NOT_TIE 并报出差额 —— 一份自己都对不上的对账单寄出去,是把内部算术错误变成一场客户争议。【同一段期间再出一次 = 新起一行】旧行落 superseded_at + 理由(必须给理由,STATEMENT_SUPERSEDE_REASON_REQUIRED),不删不改 —— 与 bank_reconciliations 的重开同一条。';

-- ───────────────────────────────────────────────────────────────────────────
-- 6 · 记一次签发 —— 第八个 record_*_issue,形状取自 record_cn_issue
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_statement_issue(
    p_statement_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s    customer_statements%ROWTYPE;
    v_next integer;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_s FROM customer_statements WHERE id = p_statement_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', COALESCE(p_statement_id::text, '?');
    END IF;

    -- 【被取代的那一份不再签发,但既有的版本仍然读得到】与 record_invoice_issue
    -- 拒 void 同一条:被取代的意思是"这一份结束了",而不是"它没发生过" ——
    -- 客户手里那一版仍然是真实寄出去过的东西。
    IF v_s.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'STATEMENT_SUPERSEDED|%|%', v_s.code,
            COALESCE(v_s.superseded_reason, '');
    END IF;

    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next
      FROM statement_issues WHERE statement_id = p_statement_id;

    INSERT INTO statement_issues (statement_id, version, file_path, sha256, issued_by)
    VALUES (p_statement_id, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('statement_id', p_statement_id, 'code', v_s.code,
                              'version', v_next, 'file_path', p_file_path);
END;
$function$;

COMMENT ON FUNCTION public.record_statement_issue(uuid, text, text) IS
    'STATEMENT-1:签发档的唯一写入口,第八个 record_*_issue,形状取自 record_cn_issue。版本号在库里裁决(并发安全),重新渲染 = 新的一版,绝不覆盖旧行 —— 客户手里那份是某个具体版本。被取代的对账单不再签发新版(STATEMENT_SUPERSEDED),但既有版本仍然读得到、取得回:被取代的意思是"这一份结束了",不是"它没发生过"。';

-- ───────────────────────────────────────────────────────────────────────────
-- 7 · 桶(第八个),与前七个同一形状
-- ───────────────────────────────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('statement-documents', 'statement-documents', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "authenticated read statement-documents"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'statement-documents'::text);

CREATE POLICY "authenticated upload statement-documents"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'statement-documents'::text);

COMMIT;
