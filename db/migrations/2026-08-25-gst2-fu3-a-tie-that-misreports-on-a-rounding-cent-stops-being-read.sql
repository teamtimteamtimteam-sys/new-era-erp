-- GST-2 fu3:税那两条腿的汇率要能【原样还原】F5 读到的那个本位币税额
--
-- 【问题】F5 的 box6(单据侧)是 **Σ 行税额**,而每一行的 tax_base 是
-- `round(该行原币税 × 汇率, 2)` —— 逐行取整。而开票分录的税腿若按单据汇率过,
-- 过进总账的是 `round(Σ原币税 × 汇率, 2)` —— 先加后取整。
-- **外币下这两个数可以差一分钱。**
--
-- 【为什么这一分钱要紧,而 amount_base 那一分钱不要紧】
-- 行的 amount_base 早就有同样的逐行取整(create_order_invoice 抬头原话:
-- "头对分录,行对纸面,两者相差不超过几分且各自自洽"),而那从来没有关系,
-- 因为**没有任何勾稽跨过那道缝**。GST-2 之后有了:box6 的单据侧读行、
-- 总账侧读 2100,而"单据 vs 总账"正是拿这两个数去比的。
-- 于是一张**完全正确**的外币发票会让勾稽报 false。
--
-- ★【而这才是真正的代价:一条会误报的勾稽,一个季度之后就没有人看了。】★
-- 这正是 Tim 裁定选项 A 时说的那句话的另一面 —— 他拒绝选项 B 的理由就是
-- 它会让勾稽"从信号退化成每季都响的噪声"。**在实现里留下一个每逢外币就响的
-- 取整误报,是把那个被拒绝的结果从后门放回来。**
--
-- 【处置:用仓库里现成的那一手】record_payment 的解除行早就这么写:
--     "行 fx = 目标基准额 ÷ 原币额(除后反乘取整恰好还原)"
-- 税腿的 fx 因此取 `Σ行本位币税 ÷ Σ行原币税`,而不是单据汇率本身。
-- post_journal_entry 反乘取整之后落进总账的,恰好就是 F5 读的那个数。
-- 【本位币(SGD)下 fx 恒为 1,这一改是恒等的】—— 今天线上一张外币税发票都没有。

BEGIN;

CREATE OR REPLACE FUNCTION public.create_order_invoice(p_sales_order_id uuid, p_issue_date date, p_payment_terms_days integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text, p_line_ids uuid[] DEFAULT NULL::uuid[], p_tax_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order    sales_orders%ROWTYPE;
    v_cust     customers%ROWTYPE;
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

    v_terms := COALESCE(p_payment_terms_days, v_cust.payment_terms_days, 30);
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
                v_line_tax := round((v_e->>'amount_ccy')::numeric * v_tax_rate / 100.0, 2);
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
    FROM invoices WHERE code LIKE 'INV-' || v_year::text || '-%';
    v_code := 'INV-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

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
                'contact_person', v_cust.contact_person,
                'email', v_cust.email,
                'phone', v_cust.phone),
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
    SELECT open_ccy INTO v_open FROM order_invoice_balance_all WHERE invoice_id = p_invoice_id;
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
    v_jlines := '[]'::jsonb;
    IF v_a_total > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '2500', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_a_total, 2), 'fx_rate', v_inv.fx_rate,
            'line_memo', 'unshipped cancelled');
    END IF;
    IF v_b_total > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '4000', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_b_total, 2), 'fx_rate', v_inv.fx_rate,
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
        'currency', v_inv.currency, 'amount_ccy', round(v_total, 2), 'fx_rate', v_inv.fx_rate);
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

COMMIT;
