-- ════════════════════════════════════════════════════════════════════════════
-- GST-2:单据开始携带税,F5 的销项侧改从【发票】推导 —— 税点是开票那一天
--
-- 【裁定(Tim,2026-08-25):选项 A —— 供应报在【开票】那一期。】
-- 新加坡的供应时点是【开票与收款孰早】,不是发货、也不是销售确认。
-- 报给 IRAS 的那一份必须合法定口径,这是第一条理由;第二条理由是形状上的:
-- 另一个接法(供应挂销售、税挂开票)会让 box1 与 box6 在【每一个季度边界】
-- 天然分开,而 GST-1 那条勾稽正是为了报告这种分开的 —— 它会从一个信号
-- 退化成每季都响的噪声,而这个仓库为"学会忽略警报"付过账。
--
-- ★【这一刀【推翻】了 GST-1 已经建成并经过 fixture 的一半,说清楚免得被读成churn】★
--   GST-1 的 F5 是【九格全部从总账推导】的,fixture 128 的 F1/F2 臂钉住过它。
--   销项侧(box1/box2/box3/box6 的文档侧)从此改为【从发票推导】。
--   被替换掉的不是一段坏代码 —— 它是对的,只是它回答的是【另一个税点】。
--   进项侧仍然从总账推导,而那不是妥协:费用单的 expense_date 就是供应商
--   税务发票的日期,总账口径与法定口径在进项侧本来就重合。
--
-- 【收款那一条腿 —— 规矩有两半,不许只做一半就当做完了】
--   "孰早"意味着【先收款后开票】同样触发供应。这条路在本仓库是通的:
--   record_payment 传空 p_allocations 会走 借银行 / 贷 1100,在应收上留下一笔
--   贷余 —— 那就是一笔客户预收。GST-2 【不实现】它,理由是实现不了:
--   收款那一刻没有任何东西说得出这笔钱对应哪一项供应,于是税码、税率、格号
--   三者都无从解析,而【猜一个】正是本仓库反复付账的那个缺陷。
--   处置不是沉默,是【按名拦住】:已注册时,一笔挂不上单据的客户收款
--   被 GST_UNALLOCATED_RECEIPT_UNSUPPORTED 拒绝。
--   返回条件写在 docs/known-issues.md。
--
-- 【税码从哪儿来 —— 两种错法都要避开】
--   每一行都要人手打的码,一定会被打错;而一个【悄悄默认】的码,是一个
--   穿着默认值外衣的错答案。所以:税码挂在【往来对象】上(customers /
--   suppliers 的 default_tax_code),初值 NULL,而 NULL + 已注册 = 按名拒
--   (TAX_CODE_REQUIRED)。它因此既不用每行打,也从不被猜 —— 它只能是
--   某个人在某一刻【明说过】的那一个,单据上还可以逐张改写。
--
-- 【冻在行上】发票一开,税码与税率就【钉死在行上】,永不按今天的设置重算 ——
--   与已承诺的价格条款同一条规矩。历史发票重打出来必须还是当时那一张。
--
-- 【开关关着时,行为与今天一模一样,而这仍然不是一句断言】
--   GST-1 把这条保证放在 post_journal_entry 上。**那道闸从今天起不够了** ——
--   box1 改从 invoice_lines 推导之后,一个盖在发票行上的税码【根本不经过总账】
--   就能让 F5 不为零。所以保证跟着搬到单据表自己身上:
--   invoice_lines / expenses / credit_note_lines 三张表各有一个触发器,
--   未注册时带税码的行【写不进去】。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 一 · 税码挂在往来对象上
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.customers
    ADD COLUMN default_tax_code text REFERENCES public.tax_codes (code);

COMMENT ON COLUMN public.customers.default_tax_code IS
    'GST-2:开给这个客户的发票默认用哪个销项税码。**初值 NULL,而 NULL 不是一个默认值,是一个未回答的问题** —— 已注册时开票会按名拒(TAX_CODE_REQUIRED|customer),因为一个悄悄默认的税码是一个穿着默认值外衣的错答案。尤其不要按国别自动推 ZR:出口零税率在法定上取决于【出口证据】,不取决于账单地址,按国别推等于把一个证据问题答成一个地址问题。';

ALTER TABLE public.suppliers
    ADD COLUMN default_tax_code text REFERENCES public.tax_codes (code);

COMMENT ON COLUMN public.suppliers.default_tax_code IS
    'GST-2:这家供应商的账单默认用哪个进项税码。初值 NULL,已注册时记费用会按名拒(TAX_CODE_REQUIRED|supplier)。与 customers.default_tax_code 逐字同一条理由。';

-- 【侧别要对得上】销项码不能挂在供应商上,反之亦然 —— 挂反了,那笔税会进
-- 一个它根本不该进的格,而 F5 照样算得出数。
CREATE OR REPLACE FUNCTION public.guard_default_tax_code_side()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE v_side text; v_want text;
BEGIN
    IF NEW.default_tax_code IS NULL THEN RETURN NEW; END IF;
    v_want := CASE TG_TABLE_NAME WHEN 'customers' THEN 'output' ELSE 'input' END;
    SELECT side INTO v_side FROM tax_codes WHERE code = NEW.default_tax_code;
    IF v_side IS DISTINCT FROM v_want THEN
        RAISE EXCEPTION 'TAX_CODE_WRONG_SIDE|%|%', NEW.default_tax_code, v_want;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_customers_default_tax_code_side
    BEFORE INSERT OR UPDATE OF default_tax_code ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.guard_default_tax_code_side();

CREATE TRIGGER trg_suppliers_default_tax_code_side
    BEFORE INSERT OR UPDATE OF default_tax_code ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION public.guard_default_tax_code_side();

-- ════════════════════════════════════════════════════════════════════════════
-- 二 · 单据行携带税 —— 【冻在行上】
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.invoice_lines
    ADD COLUMN tax_code     text REFERENCES public.tax_codes (code),
    ADD COLUMN tax_rate_pct numeric,
    ADD COLUMN tax_base     numeric NOT NULL DEFAULT 0,
    ADD CONSTRAINT invoice_lines_tax_shape CHECK (
        (tax_code IS NULL     AND tax_rate_pct IS NULL     AND tax_base = 0)
     OR (tax_code IS NOT NULL AND tax_rate_pct IS NOT NULL AND tax_base >= 0));

COMMENT ON COLUMN public.invoice_lines.tax_code IS
    'GST-2:这一行在 GST 上是什么性质,【开票那一刻冻在行上】。F5 的 box1/box2/box3 从这一列推导 —— 税点是开票日,所以供应额的期间由 invoices.issue_date 决定,不由销售日决定。';
COMMENT ON COLUMN public.invoice_lines.tax_rate_pct IS
    'GST-2:开票日经 tax_rate_for(code, invoices.issue_date) 解析出来的税率,【抄下来冻住】。一张已开出的发票永远不按今天的设置重算它的税 —— 与已承诺的价格条款同一条规矩。2022 年那张票永远是 7%。';

ALTER TABLE public.expenses
    ADD COLUMN tax_code     text REFERENCES public.tax_codes (code),
    ADD COLUMN tax_rate_pct numeric,
    ADD COLUMN tax_base     numeric NOT NULL DEFAULT 0,
    ADD CONSTRAINT expenses_tax_shape CHECK (
        (tax_code IS NULL     AND tax_rate_pct IS NULL     AND tax_base = 0)
     OR (tax_code IS NOT NULL AND tax_rate_pct IS NOT NULL AND tax_base >= 0));

COMMENT ON COLUMN public.expenses.tax_base IS
    'GST-2:本单的进项税,以【本位币】计。**amount_ccy 始终是不含税的净额** —— 供应商账单上的总额 = 净额 + 税。可抵的(TX/ZP)那一笔税借 1400 进项税;不可抵的(BL)【有税但要不回来】,那笔税借进费用科目本身、且【不带税码】,好让 box5 报的仍然是采购净额。';

ALTER TABLE public.credit_note_lines
    ADD COLUMN tax_code     text REFERENCES public.tax_codes (code),
    ADD COLUMN tax_rate_pct numeric,
    ADD COLUMN tax_base     numeric NOT NULL DEFAULT 0,
    ADD CONSTRAINT credit_note_lines_tax_shape CHECK (
        (tax_code IS NULL     AND tax_rate_pct IS NULL     AND tax_base = 0)
     OR (tax_code IS NOT NULL AND tax_rate_pct IS NOT NULL AND tax_base >= 0));

COMMENT ON COLUMN public.credit_note_lines.tax_code IS
    'GST-2:贷项凭证行的税码,【从它冲的那一张发票行抄来】—— 不重新解析。冲的是哪一笔供应,就退哪一笔供应的税,连税率一起,即便法定税率此后变过。一张贷项凭证在 F5 上是一笔【负的供应】。';

-- ════════════════════════════════════════════════════════════════════════════
-- 三 · GST-OFF 的结构性保证,搬到单据表上
--
-- 【为什么必须搬】GST-1 把它放在 post_journal_entry 上,那时 F5 九格全部
-- 从总账推导,所以"总账里没有带税码的行"= "F5 全零"。**GST-2 之后这句不再成立**:
-- box1 改从 invoice_lines 推导,一个盖在发票行上的税码不经过总账就能让 F5 不为零。
-- 一道只守着旧路径的闸,在新路径开通的那一刻就不再是闸了。
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.guard_document_tax_code()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.tax_code IS NOT NULL AND NOT gst_registered() THEN
        RAISE EXCEPTION 'GST_NOT_REGISTERED|%', NEW.tax_code;
    END IF;
    RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.guard_document_tax_code() IS
    'GST-2:未注册时,单据行上【写不进】税码。这是 GST-1 那条"关掉开关 = 与建 GST 之前一模一样"的保证在单据侧的落点 —— post_journal_entry 上那一份只守总账,而 F5 的销项侧从 GST-2 起根本不经过总账。';

CREATE TRIGGER trg_invoice_lines_tax_code_registered
    BEFORE INSERT OR UPDATE OF tax_code ON public.invoice_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_document_tax_code();

CREATE TRIGGER trg_expenses_tax_code_registered
    BEFORE INSERT OR UPDATE OF tax_code ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.guard_document_tax_code();

CREATE TRIGGER trg_credit_note_lines_tax_code_registered
    BEFORE INSERT OR UPDATE OF tax_code ON public.credit_note_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_document_tax_code();

-- ════════════════════════════════════════════════════════════════════════════
-- 四 · sale 型发票从此【可以有一张分录】—— 那张分录【只过税】
--
-- 【为什么只过税】收入在【销售】那一刻已经确认过(record_output_sale:
-- 借 1100 应收 / 贷 4000 收入)。开票再过一次收入就是把同一笔生意记两遍。
-- 而税【从来没有人过过】—— invoices.total_base 一直写着 subtotal + tax,
-- 那句话至今没有在总账里兑现过。这张分录就是兑现它:借 1100 / 贷 2100。
--
-- 【约束改成"恰好对应"而不是"一律为空"】sale 型有没有分录,由它带不带税决定。
-- 这比原来的"sale ⇒ entry_id IS NULL"更紧,不是更松:它把两列钉成一件事。
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.invoices DROP CONSTRAINT invoices_kind_consistency;
ALTER TABLE public.invoices ADD CONSTRAINT invoices_kind_consistency CHECK (
    (kind = 'sale'  AND sales_order_id IS NULL AND fx_rate IS NULL
                    AND (entry_id IS NOT NULL) = (tax_base <> 0))
 OR (kind = 'order' AND sales_order_id IS NOT NULL AND entry_id IS NOT NULL
                    AND fx_rate IS NOT NULL AND fx_rate > 0));

COMMENT ON CONSTRAINT invoices_kind_consistency ON public.invoices IS
    'GST-2 改写:sale 型发票【带税就有分录,不带税就没有】—— 那张分录只过税(借 1100 / 贷 2100),收入在销售那一刻已经认过。GST-2 之前这里写的是 sale ⇒ entry_id IS NULL,因为那时 sale 型什么都不过账。改后【更紧】:两列被钉成同一件事,而不是各说各话。';

-- ════════════════════════════════════════════════════════════════════════════
-- 五 · 税码怎么解析 —— 一个地方,不是四个
--
-- 【两种错法】每行手打的码一定会被打错;悄悄默认的码是穿着默认值外衣的错答案。
-- 所以这支函数只做一件事:**要么拿到一个有人明说过的码,要么按名拒绝。**
-- 它【不猜】—— 尤其不按国别猜 ZR:出口零税率取决于出口证据,不取决于账单地址。
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.resolve_tax_code(p_override text, p_default text, p_side text, p_subject text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_code text; v_side text; v_active boolean;
BEGIN
    v_code := COALESCE(NULLIF(btrim(COALESCE(p_override, '')), ''), p_default);
    IF v_code IS NULL THEN
        -- 【这不是"没有税",是"没有人回答过"】两者在 F5 上完全不同:
        -- 一个 0 会安静地进表,一个拒绝会把问题交还给能回答它的人。
        RAISE EXCEPTION 'TAX_CODE_REQUIRED|%', p_subject
          USING HINT = '给这个往来对象设一个默认税码,或在这张单据上指定一个';
    END IF;
    SELECT side, is_active INTO v_side, v_active FROM tax_codes WHERE code = v_code;
    IF v_side IS NULL THEN
        RAISE EXCEPTION 'TAX_CODE_UNKNOWN|%', v_code;
    END IF;
    IF NOT v_active THEN
        RAISE EXCEPTION 'TAX_CODE_INACTIVE|%', v_code;
    END IF;
    IF v_side <> p_side THEN
        -- 挂反了的码照样算得出数,却会进一个它根本不该进的格。
        RAISE EXCEPTION 'TAX_CODE_WRONG_SIDE|%|%', v_code, p_side;
    END IF;
    RETURN v_code;
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 六 · 冲销要把税码一起翻过去
--
-- 【这是 GST-2 撞出来的一个真缺陷,不是新功能】reverse_journal_entry_internal
-- 翻边时【不抄 tax_code】。GST-1 时代这不要紧:没有任何一行带税码。
-- GST-2 之后要紧得很 —— box5 是 Σ(借−贷) FILTER (tax_code IN (TX,ZP,BL)),
-- 冲销行不带码就冲不掉那笔采购,于是一笔【已经冲销的】进货会永远留在 box5 里,
-- 而总账本身是平的、没有任何东西看起来不对。
-- ════════════════════════════════════════════════════════════════════════════

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
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 七 · create_invoice —— 发票开始携带税,并且【过一张只有税的分录】
--
-- 【改掉的是什么】此前它读 finance_settings.gst_rate_pct 这个【标量】算税,
-- 而且一张分录都不过。标量表达不了税率史(2022 年那张票永远是 7%),
-- 也表达不了零税率 / 豁免 / 不在范围内这三件不同的事。
-- 【为什么分录只过税】收入在【销售】那一刻已经认过(借 1100 / 贷 4000)。
-- 开票再认一次就是把同一笔生意记两遍。而税从来没有人过过 ——
-- invoices.total_base 一直写着 subtotal + tax,这张分录是第一次在总账里兑现它。
-- 【p_tax_code 加在参数表末尾、且有默认值】FIN-10 的先例:老调用方少传一个参数时
-- 应当拿到一句人话,而不是 "function does not exist"。
-- ════════════════════════════════════════════════════════════════════════════

-- 【先 DROP 旧签名 —— 加一个参数是【重载】,不是替换】不 DROP 的话线上会同时
-- 活着两个 create_invoice,而镜像里只有一个:老的那一个会继续被任何仍按旧签名
-- 调用的地方命中,而它【不算税、不过分录】—— 一条安静地绕过整个 GST-2 的路。
-- preflight_migration.py 的重载判词点的就是这件事。
DROP FUNCTION IF EXISTS public.create_invoice(uuid, uuid[], date, integer, text, text);

CREATE OR REPLACE FUNCTION public.create_invoice(p_customer_id uuid, p_sales_record_ids uuid[], p_issue_date date DEFAULT NULL::date, p_payment_terms_days integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text, p_tax_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cust        customers%ROWTYPE;
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

    IF p_sales_record_ids IS NULL OR array_length(p_sales_record_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- 2. 账期:显式 > 客户设定 > 30 天
    v_terms := COALESCE(p_payment_terms_days, v_cust.payment_terms_days, 30);
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
    WHERE code LIKE 'INV-' || v_year::text || '-%';
    v_code := 'INV-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

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
                           ELSE round(v_sale.amount_base * v_tax_rate / 100.0, 2) END;

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
                'contact_person', v_cust.contact_person,
                'email', v_cust.email,
                'phone', v_cust.phone),
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
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 八 · record_expense —— 进项侧接线
--
-- 【p_amount 的口径没有变,而这一点要写清楚】它始终是【不含税净额】。
-- GST 关着时净额 = 总额,所以既有行为逐字不变;开着时供应商账单上的总额
-- 是净额 + 税,那笔税另有去处。
-- 【可抵 vs 不可抵,两条完全不同的路】
--   TX / ZP:税借 1400 进项税 → 进 box7,要得回来;
--   BL:税借【费用科目本身】且那条腿不带税码 → 采购净额仍然进 box5,
--       税不进 box7 —— "有税但要不回来"。
--   而资本支出上那笔不可抵的税【进资产成本】:它和买价一样是为取得资产付出去的钱。
-- 【进项侧的税点】供应商税务发票的日期 = p_expense_date。所以进项侧仍然
-- 从总账推导 —— 总账口径与法定口径在这一侧本来就重合,不是妥协。
-- ════════════════════════════════════════════════════════════════════════════

-- 同上:加 p_tax_code 是重载,旧签名必须在同一支迁移里 DROP 掉。
DROP FUNCTION IF EXISTS public.record_expense(date, text, numeric, text, numeric, text, text, uuid, text, text, jsonb, uuid, uuid);

CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid, p_tax_code text DEFAULT NULL::text)
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
        v_tax_ccy  := round(p_amount * v_tax_rate / 100.0, 2);
        v_tax_base := round(v_tax_ccy * v_fx, 2);
        SELECT is_claimable INTO v_claimable FROM tax_codes WHERE code = v_tax_code;
    ELSE
        -- 【未注册:与建 GST 之前一模一样】传了码要按名拒,不能悄悄忽略。
        IF NULLIF(btrim(COALESCE(p_tax_code, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'GST_NOT_REGISTERED|%', p_tax_code;
        END IF;
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
    WHERE code LIKE 'EXP-' || v_year::text || '-%';
    v_code := 'EXP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

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
                          tax_code, tax_rate_pct, tax_base)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, p_amount, p_currency, v_fx,
            v_amount_base, p_payment_status, v_bank, p_supplier_id, p_employee_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user,
            p_purchase_order_line,
            v_tax_code,
            CASE WHEN v_tax_code IS NULL THEN NULL ELSE v_tax_rate END,
            v_tax_base);

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
            -- 【投用之后成本就冻住了】投用那一刻起折旧按它算;再往上加钱,
            -- 已经提过的那几期就全错了 —— 而它们已经过账,可能已经锁进期间。
            -- 投用后的追加是一次【会计判断】(资本化改良 vs 当期费用),
            -- 不是这条路顺手做得了的事,所以按名拒,把那个判断交还给人。
            IF v_target.in_service_date IS NOT NULL THEN
                RAISE EXCEPTION 'ASSET_ALREADY_IN_SERVICE|%|%', v_target.code, v_target.in_service_date;
            END IF;
            IF v_target.status <> 'active' THEN
                RAISE EXCEPTION 'ASSET_DISPOSED|%', v_target.code;
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

            RETURN jsonb_build_object(
                'expense_id', v_expense_id,
                'asset_id', v_append_id, 'asset_code', v_target.code,
                'asset_mode', 'append',
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
        'payment_status', p_payment_status
    );
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════════
-- 九 · create_order_invoice —— 那条"明确不支持"的拒绝退休了
--
-- INVOICE_ORDER_GST_UNSUPPORTED 原本是一条【诚实的】拒绝:它等的是一个
-- 没有人回答过的问题(预收发票的销项税时点与科目)。Tim 2026-08-25 的裁定
-- 回答了它 —— 税点是开票,科目是 2100。**一条等到了答案的拒绝要退休,
-- 而不是留在原地继续拒。** 留着它,开关打开的那一天整条订单开票路会停摆。
-- ════════════════════════════════════════════════════════════════════════════

-- 同上。
DROP FUNCTION IF EXISTS public.create_order_invoice(uuid, date, integer, text, text, uuid[]);

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
            jsonb_build_object('account_code', '1100', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_tax, 'fx_rate', v_order.fx_rate,
                'line_memo', 'output tax ' || v_tax_code),
            jsonb_build_object('account_code', '2100', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_tax, 'fx_rate', v_order.fx_rate,
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
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 九之二 · create_credit_note —— 一张贷项凭证是一笔【负的供应】
--
-- 【税码从被冲的那一行【抄】来,不重新解析】冲的是哪一笔供应,就退哪一笔供应的
-- 税,连它当时那个税率一起 —— 即便法定税率此后变过。按凭证日重算,会用今天的
-- 税率去退一笔按去年税率收过的税,而差额无声地留在 2100 里。
-- 与"币种与汇率抄发票的"逐字同一条理由(CN-1 抬头)。
-- ════════════════════════════════════════════════════════════════════════════

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
        v_jlines := v_jlines || jsonb_build_object('account_code', '2100', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_tax_total, 2), 'fx_rate', v_inv.fx_rate,
            'line_memo', 'output tax reversed');
    END IF;
    -- 【净额与税分成两条贷方腿】逐行 round(原币 × 汇率) 之下,一条合并腿会与
    -- 借方两条差一分钱 —— 与 record_expense / create_order_invoice 同一条理由。
    v_jlines := v_jlines || jsonb_build_object('account_code', '1100', 'side', 'credit',
        'currency', v_inv.currency, 'amount_ccy', round(v_total, 2), 'fx_rate', v_inv.fx_rate);
    IF round(v_tax_total, 2) > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '1100', 'side', 'credit',
            'currency', v_inv.currency, 'amount_ccy', round(v_tax_total, 2), 'fx_rate', v_inv.fx_rate,
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
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 九之三 · void_invoice —— sale 型从此【可能有一张分录要冲】
-- ════════════════════════════════════════════════════════════════════════════

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
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 九之四 · record_payment —— "孰早"那条规矩的另一半,按名拦住
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.record_payment(p_direction text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_payment_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb, p_counterparty_kind text DEFAULT NULL::text)
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
BEGIN
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    PERFORM require_permission('module.finance.edit');
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
                SELECT i.id, i.code AS doc_code, i.customer_id AS party_id,
                       (SELECT COALESCE(sum(il.amount_ccy), 0) FROM invoice_lines il
                         WHERE il.invoice_id = i.id) AS doc_value,
                       i.currency AS doc_ccy, i.fx_rate AS doc_fx
                INTO v_doc
                FROM invoices i
                WHERE i.id = v_invoice_id AND i.kind = 'order' AND i.status = 'issued';
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
            SELECT e.id, e.code AS doc_code, COALESCE(e.supplier_id, e.employee_id) AS party_id,
                   e.amount_ccy AS doc_value, e.currency AS doc_ccy, e.fx_rate AS doc_fx
            INTO v_doc
            FROM expenses e
            WHERE e.id = v_expense_id AND e.payment_status = 'unpaid' AND e.status = 'posted';
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_expense_id;
            END IF;
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
            'amount_pay', v_alloc_pay));
        v_alloc_total := v_alloc_total + v_alloc_usd;
    END LOOP;

    -- Σ 核销不得超过款额(欠核销 = 挂账余额,允许)
    -- 【与页面同一个毛病的服务端孪生】v_alloc_total 是【单据币种】的合计,
    -- p_amount 是【付款币种】。同币种时看不出来;一旦不同,就是两种货币相减。
    -- 比较必须在付款币种空间做 —— 这正是两切次前在 /finance/payments 上修掉的
    -- 那个 bug,只是长在服务端。
    IF round(v_alloc_pay_total, 2) > p_amount THEN
        RAISE EXCEPTION 'ALLOC_EXCEEDS_PAYMENT|%|%', round(v_alloc_pay_total, 2), p_amount;
    END IF;
    -- 【FIN-3 修订的 C2】已实现汇兑在【结算时点】认列:
    --   控制科目按【单据的】汇率解除(不变);银行按【结算日】口径(牌价/实际);
    --   差额进 7100(已实现)。只要单据汇率和当日汇率,两个数,不追每一块钱的均价。
    -- 未核销部分与预付(非货币,按付款日历史汇率入账)都按当日口径,不产生已实现差异。
    v_bank_base    := round(p_amount * v_fx, 2);
    v_amount_base  := v_bank_base;
    -- 未核销 = 款额 − 【已消耗的付款币种额】。原先减的是 v_alloc_total(单据币种合计)
    -- —— 同币种时相等,不同币种时就是两种货币相减,与 ALLOC_EXCEEDS_PAYMENT 同一个错。
    v_unalloc_ccy  := round(p_amount - v_alloc_pay_total, 2);
    v_unalloc_base := round(v_unalloc_ccy * v_fx, 2);

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
    v_code := fin_next_payment_code(CASE WHEN p_direction = 'in' THEN 'RCPT' ELSE 'PMT' END, v_date);

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
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'credit',
            'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_bank_base / p_amount);
        -- 借方合计 − 银行贷方:>0 说明按旧率解除得多 → 贷 7100(益);<0 → 借 7100(损)
        v_realised := round((v_base_total - v_po_base) + v_unalloc_base + v_po_pay_base - v_bank_base, 2);
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
                                         allocated_ccy, allocated_base, allocated_pay)
        VALUES (v_payment_id,
                (v_alloc->>'sales_record_id')::uuid,
                (v_alloc->>'inbound_batch_id')::uuid,
                (v_alloc->>'expense_id')::uuid,
                (v_alloc->>'purchase_order_id')::uuid,
                (v_alloc->>'invoice_id')::uuid,
                (v_alloc->>'freight_document_id')::uuid,
                (v_alloc->>'amount_ccy')::numeric,
                (v_alloc->>'amount_base')::numeric,
                (v_alloc->>'amount_pay')::numeric);
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
        -- 单据币种的核销额【按币种分开列】,不求和
        'settled_by_ccy', (SELECT COALESCE(jsonb_object_agg(key, value->'ccy'), '{}'::jsonb)
                             FROM jsonb_each(v_ctrl)),
        'prepaid_by_ccy', (SELECT COALESCE(jsonb_object_agg(key, value->'ccy'), '{}'::jsonb)
                             FROM jsonb_each(v_pre))
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 十 · F5 —— 销项侧改从【发票】推导,进项侧仍走总账
--
-- 【逐格的来源,写在这里,因为"这一格是从哪儿来的"是这份表最要紧的一件事】
--   box1 / box2 / box3  供应额   ← **发票行**(按 invoices.issue_date 落期间)
--                                  减【贷项凭证行】(按 credit_notes.note_date)
--   box4                合计     ← 1 + 2 + 3(算出来的,钻不进去)
--   box5                采购额   ← **总账**(带 TX/ZP/BL 的分录行,借−贷)
--   box6                销项税   ← **发票行的税**减【贷项凭证行的税】
--   box7                进项税   ← **总账**(1400 科目,借−贷)
--   box8                净额     ← 6 − 7(算出来的,钻不进去)
--   box9                进口计划 ← 结构性为零,我们不参加(derived=false)
--   box13               营业收入 ← **总账**(收入类科目)—— 这是会计口径的收入,
--                                  它与 box1【本来就会】在季度边界上不同:
--                                  box1 是开票口径。这不是错,是两个不同的问题。
--
-- 【为什么销项侧换了、进项侧没换 —— 这不是不彻底,是两侧的税点本来就不同】
--   销项:税点 = 开票日,而这套账在【销售】那一刻确认收入 —— 两者会跨季分开,
--         所以供应额必须离开总账,回到发票上去。
--   进项:税点 = 供应商税务发票的日期,而 record_expense 的 expense_date 记的
--         正是那一天 —— 总账口径与法定口径在这一侧【重合】,没有要修的东西。
--
-- ★【勾稽:三个来源,两条比较 —— 而且都真的会分开】★
--   GST-2 之后,销项税这一个数在系统里有【三处】各自说得出来的说法:
--     ① 单据:发票行上冻住的那笔税(客户手里那张纸上印的);
--     ② 法令:供应额 × 【开票那一天】的法定税率(谁都没读、当场重算的);
--     ③ 总账:2100 科目上的余额(过账留下的)。
--   只比两处,第三处就没有人看着。所以这里比两条:① vs ②(单据对法令)、
--   ① vs ③(单据对总账)。**两条都成立才算勾稽上。**
--   · ①≠② = 发票上的税与法令对不上(税率错、金额错、税被人改过);
--   · ①≠③ = 单据与总账对不上(某张票没过账、作废没冲销、有人手工动过 2100)。
--   fixture 129 各自把两条弄分开过。
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.f5_return(p_period_start date, p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_box1 numeric := 0; v_box2 numeric := 0; v_box3 numeric := 0;
    v_box5 numeric := 0; v_box6 numeric := 0; v_box7 numeric := 0;
    v_box13 numeric := 0;
    v_inv1 numeric := 0; v_inv2 numeric := 0; v_inv3 numeric := 0; v_inv_tax numeric := 0;
    v_cn1  numeric := 0; v_cn2  numeric := 0; v_cn3  numeric := 0; v_cn_tax  numeric := 0;
    v_stat_inv numeric := 0; v_stat_cn numeric := 0;
    v_box6_docs    numeric := 0;   -- ① 单据
    v_box6_statute numeric := 0;   -- ② 法令
    v_box6_ledger  numeric := 0;   -- ③ 总账
    v_base text;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'GST_PERIOD_DATES_REQUIRED';
    END IF;
    IF p_period_end < p_period_start THEN
        RAISE EXCEPTION 'GST_PERIOD_WINDOW_INVALID|%|%', p_period_start, p_period_end;
    END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ── 供应额与销项税:【发票】────────────────────────────────────────────
    -- 【作废的票不算】它对外已经不成立了;而它那张只过税的分录也已冲销,
    -- 所以两条勾稽都跟着一起走。
    SELECT
      COALESCE(SUM(il.amount_base) FILTER (WHERE il.tax_code = 'SR'), 0),
      COALESCE(SUM(il.amount_base) FILTER (WHERE il.tax_code = 'ZR'), 0),
      COALESCE(SUM(il.amount_base) FILTER (WHERE il.tax_code = 'ES'), 0),
      COALESCE(SUM(il.tax_base), 0)
      INTO v_inv1, v_inv2, v_inv3, v_inv_tax
      FROM invoice_lines il
      JOIN invoices i ON i.id = il.invoice_id
     WHERE i.issue_date BETWEEN p_period_start AND p_period_end
       AND i.status <> 'void';

    -- ── 贷项凭证:一笔【负的供应】,按凭证自己的单据日落期间 ────────────────
    SELECT
      COALESCE(SUM(round(cnl.amount * cn.fx_rate, 2)) FILTER (WHERE cnl.tax_code = 'SR'), 0),
      COALESCE(SUM(round(cnl.amount * cn.fx_rate, 2)) FILTER (WHERE cnl.tax_code = 'ZR'), 0),
      COALESCE(SUM(round(cnl.amount * cn.fx_rate, 2)) FILTER (WHERE cnl.tax_code = 'ES'), 0),
      COALESCE(SUM(cnl.tax_base), 0)
      INTO v_cn1, v_cn2, v_cn3, v_cn_tax
      FROM credit_note_lines cnl
      JOIN credit_notes cn ON cn.id = cnl.credit_note_id
     WHERE cn.note_date BETWEEN p_period_start AND p_period_end;

    v_box1 := v_inv1 - v_cn1;
    v_box2 := v_inv2 - v_cn2;
    v_box3 := v_inv3 - v_cn3;
    v_box6_docs := v_inv_tax - v_cn_tax;

    -- ── ② 法令:当场按【单据自己那一天】的法定税率重算,不读任何冻住的值 ──
    SELECT COALESCE(SUM(round(il.amount_base * tax_rate_for(il.tax_code, i.issue_date) / 100.0, 2)), 0)
      INTO v_stat_inv
      FROM invoice_lines il
      JOIN invoices i ON i.id = il.invoice_id
     WHERE i.issue_date BETWEEN p_period_start AND p_period_end
       AND i.status <> 'void'
       AND il.tax_code IS NOT NULL;
    -- 【贷项凭证按【它冲的那张发票】的开票日取税率】退的是那一笔供应的税,
    -- 而那笔税是按当年的法定税率收的 —— 按凭证日重算会用今天的税率退去年的税。
    SELECT COALESCE(SUM(round(round(cnl.amount * cn.fx_rate, 2)
                              * tax_rate_for(cnl.tax_code, oi.issue_date) / 100.0, 2)), 0)
      INTO v_stat_cn
      FROM credit_note_lines cnl
      JOIN credit_notes cn ON cn.id = cnl.credit_note_id
      JOIN invoice_lines oil ON oil.id = cnl.invoice_line_id
      JOIN invoices oi ON oi.id = oil.invoice_id
     WHERE cn.note_date BETWEEN p_period_start AND p_period_end
       AND cnl.tax_code IS NOT NULL;
    v_box6_statute := v_stat_inv - v_stat_cn;

    -- ── ③ 总账:2100 科目本身 ──────────────────────────────────────────────
    SELECT COALESCE(SUM(jl.credit - jl.debit), 0) INTO v_box6_ledger
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.code = '2100' AND je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    -- 【报出去的那一格用【单据】那一个】客户手里那张纸上印的就是它,
    -- 而 IRAS 问的是"你开出去的税是多少"。另外两条是用来验它的,不是用来替它的。
    v_box6 := v_box6_docs;

    -- ── 采购额与进项税:【总账】—— 进项侧的税点与记账时点重合 ───────────────
    -- BL(不可抵)【也要报采购额】,只是税不抵 —— 那正是税码存在的理由。
    SELECT COALESCE(SUM(jl.debit - jl.credit) FILTER (WHERE jl.tax_code IN ('TX','ZP','BL')), 0)
      INTO v_box5
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
     WHERE je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    SELECT COALESCE(SUM(jl.debit - jl.credit), 0) INTO v_box7
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.code = '1400' AND je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    -- 【Box 13 收入】会计口径的总收入,从收入类科目取。**它与 box1 在季度边界上
    -- 本来就会不同** —— box1 是开票口径、box13 是确认口径。两个不同的问题。
    SELECT COALESCE(SUM(jl.credit - jl.debit), 0) INTO v_box13
      FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
      JOIN accounts a ON a.id = jl.account_id
     WHERE a.account_type = 'revenue' AND je.entry_date BETWEEN p_period_start AND p_period_end
       AND je.status = 'posted';

    RETURN jsonb_build_object(
      'period_start', p_period_start, 'period_end', p_period_end, 'currency', v_base,
      'boxes', jsonb_build_array(
        jsonb_build_object('box','box1','label_en','Total value of standard-rated supplies','label_zh','标准税率供应总额','value', round(v_box1,2),'derived',true,'source','invoices'),
        jsonb_build_object('box','box2','label_en','Total value of zero-rated supplies','label_zh','零税率供应总额','value', round(v_box2,2),'derived',true,'source','invoices'),
        jsonb_build_object('box','box3','label_en','Total value of exempt supplies','label_zh','豁免供应总额','value', round(v_box3,2),'derived',true,'source','invoices'),
        jsonb_build_object('box','box4','label_en','Total value of (1) + (2) + (3)','label_zh','(1)+(2)+(3) 合计','value', round(v_box1+v_box2+v_box3,2),'derived',true,'source','computed'),
        jsonb_build_object('box','box5','label_en','Total value of taxable purchases','label_zh','应税采购总额','value', round(v_box5,2),'derived',true,'source','ledger'),
        jsonb_build_object('box','box6','label_en','Output tax due','label_zh','应缴销项税','value', round(v_box6,2),'derived',true,'source','invoices'),
        jsonb_build_object('box','box7','label_en','Input tax and refunds claimed','label_zh','已抵进项税与退税','value', round(v_box7,2),'derived',true,'source','ledger'),
        jsonb_build_object('box','box8','label_en','Net GST to be paid to / claimed from IRAS','label_zh','应缴/应退 GST 净额','value', round(v_box6 - v_box7,2),'derived',true,'source','computed'),
        jsonb_build_object('box','box9','label_en','Total value of goods imported under approved schemes','label_zh','按核准计划进口的货物总额','value', 0,'derived',false,'source','none',
                           'note_en','Structurally zero: this company is not on MES or any approved import scheme.','note_zh','结构性为零:本公司不在 MES 或任何核准进口计划内。'),
        jsonb_build_object('box','box13','label_en','Revenue','label_zh','营业收入','value', round(v_box13,2),'derived',true,'source','ledger')
      ),
      -- 【勾稽:三处说法,两条比较 —— 两条都成立才算勾稽上】
      'ties', jsonb_build_object(
        'box6_from_documents', round(v_box6_docs,2),
        'box6_recomputed_from_statute', round(v_box6_statute,2),
        'box6_from_tax_account', round(v_box6_ledger,2),
        'agrees_documents_vs_statute', round(v_box6_docs,2) = round(v_box6_statute,2),
        'agrees_documents_vs_ledger',  round(v_box6_docs,2) = round(v_box6_ledger,2),
        'agrees', round(v_box6_docs,2) = round(v_box6_statute,2)
                  AND round(v_box6_docs,2) = round(v_box6_ledger,2),
        'how_en','Output tax is stated three times over: frozen on the invoice line, recomputed here from the statutory rate for the invoice''s own date, and posted to account 2100. Two comparisons, both must hold. Documents vs statute catches a wrong rate or a tampered figure; documents vs ledger catches an invoice that never posted, a void that never reversed, or a hand-made entry against 2100.',
        'how_zh','销项税在系统里有三处说法:冻在发票行上的、按【开票那一天】的法定税率当场重算的、以及过进 2100 科目的。两条比较都必须成立。单据对法令,抓的是税率错或数被人改过;单据对总账,抓的是某张票没过账、作废没冲销、或有人手工动过 2100。'
      ),
      'coverage', jsonb_build_object(
        'wired_en','Output side: invoices (sale and order kinds) and credit notes, by the document''s own date — Singapore''s time of supply is the earlier of invoice or payment, and the invoice half is what is implemented. Input side: journal lines carrying an input tax code, whose posting date is the supplier tax invoice date. NOT covered: a customer payment received before any invoice — refused by name (GST_UNALLOCATED_RECEIPT_UNSUPPORTED) rather than reported untaxed.',
        'wired_zh','销项侧:发票(sale 与 order 两种)与贷项凭证,按单据自己的日期落期间 —— 新加坡的供应时点是【开票与收款孰早】,这里实现的是开票那一半。进项侧:带进项税码的分录行,其过账日就是供应商税务发票的日期。**没有覆盖的**:先于任何发票收到的客户款 —— 它被按名拒绝(GST_UNALLOCATED_RECEIPT_UNSUPPORTED),而不是无声地当成没有税。'
      ));
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 十一 · 钻回单据 —— 而"单据"现在有两种,所以返回的形状要能同时说出两种
--
-- GST-1 的返回列是分录的形状(entry_id / entry_code / source_type)。销项侧
-- 现在钻回的是【发票与贷项凭证】,它们不是分录 —— 硬塞进分录的列名会让
-- 一个发票编号顶着 entry_code 的名字出现,而那正是"机器文字到了人面前"
-- 那一类的错。列名因此改成单据中性的:doc_kind 说这是什么,其余四列跟着它读。
-- 【返回类型变了 ⇒ 必须先 DROP】CREATE OR REPLACE 改不了返回类型。
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.f5_box_detail(date, date, text);

CREATE OR REPLACE FUNCTION public.f5_box_detail(p_period_start date, p_period_end date, p_box text)
 RETURNS TABLE(doc_kind text, doc_id uuid, doc_code text, doc_date date, memo text, tax_code text, amount_base numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_box IS NULL THEN RAISE EXCEPTION 'GST_BOX_REQUIRED'; END IF;
    IF p_box NOT IN ('box1','box2','box3','box5','box6','box7') THEN
        -- 【合计格与结构性零格【钻不进去】,而这要说出来,不能返回空集】
        -- box4 与 box8 是别的格加出来的,box9 是"我们不参加",box13 是收入总额。
        RAISE EXCEPTION 'GST_BOX_NOT_DRILLABLE|%', p_box;
    END IF;

    IF p_box IN ('box1','box2','box3','box6') THEN
        -- ── 销项侧:发票行 + 贷项凭证行(后者是负数)────────────────────────
        RETURN QUERY
        SELECT 'invoice'::text, i.id, i.code, i.issue_date,
               il.description, il.tax_code,
               CASE WHEN p_box = 'box6' THEN round(il.tax_base, 2)
                    ELSE round(il.amount_base, 2) END
          FROM invoice_lines il
          JOIN invoices i ON i.id = il.invoice_id
         WHERE i.issue_date BETWEEN p_period_start AND p_period_end
           AND i.status <> 'void'
           AND il.tax_code IS NOT NULL
           AND (   (p_box = 'box1' AND il.tax_code = 'SR')
                OR (p_box = 'box2' AND il.tax_code = 'ZR')
                OR (p_box = 'box3' AND il.tax_code = 'ES')
                OR (p_box = 'box6' AND il.tax_base <> 0))
        UNION ALL
        SELECT 'credit_note'::text, cn.id, cn.code, cn.note_date,
               'CN ' || cn.reason, cnl.tax_code,
               CASE WHEN p_box = 'box6' THEN -round(cnl.tax_base, 2)
                    ELSE -round(cnl.amount * cn.fx_rate, 2) END
          FROM credit_note_lines cnl
          JOIN credit_notes cn ON cn.id = cnl.credit_note_id
         WHERE cn.note_date BETWEEN p_period_start AND p_period_end
           AND cnl.tax_code IS NOT NULL
           AND (   (p_box = 'box1' AND cnl.tax_code = 'SR')
                OR (p_box = 'box2' AND cnl.tax_code = 'ZR')
                OR (p_box = 'box3' AND cnl.tax_code = 'ES')
                OR (p_box = 'box6' AND cnl.tax_base <> 0))
         ORDER BY 4, 3;
    ELSE
        -- ── 进项侧:仍然是分录 ──────────────────────────────────────────────
        RETURN QUERY
        SELECT 'journal_entry'::text, je.id, je.code, je.entry_date,
               COALESCE(jl.line_memo, je.memo), jl.tax_code,
               round(jl.debit - jl.credit, 2)
          FROM journal_lines jl
          JOIN journal_entries je ON je.id = jl.entry_id
          LEFT JOIN accounts a ON a.id = jl.account_id
         WHERE je.entry_date BETWEEN p_period_start AND p_period_end
           AND je.status = 'posted'
           AND (   (p_box = 'box5' AND jl.tax_code IN ('TX','ZP','BL'))
                OR (p_box = 'box7' AND a.code = '1400'))
         ORDER BY je.entry_date, je.code;
    END IF;
END;
$function$;

COMMIT;
