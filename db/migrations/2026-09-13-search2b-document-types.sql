-- SEARCH-2b · 迁移 B —— document_types,以及 44 支函数体的机械变换
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★★ 这一支是【一笔事务,不可再分】★★★
--   表、40 行种子、44 支函数体,三者【必须同生同死】。少一行种子而新函数体已经
--   上线,生产上就是【开不出任何单据】—— document_type_prefix() 找不到那一行就抛。
--   所以它们写在同一个 BEGIN/COMMIT 里,而这不是风格,是这支迁移唯一安全的形状。
--
-- ★★★ 它【不是】增量的 —— 破窗在这里是真的 ★★★
--   A / C / D 都只是加东西,旧代码看不见也碰不到。B 重写了 44 支函数体:
--   提交的那一刻起,生产上每一次开单据走的都是新路径,而新代码还没部署。
--   安全性由三件事撑着,缺一不可:
--     ① 签名一个字没变(调用方不必知道这件事发生过);
--     ② 种子与函数体同一笔事务(见上);
--     ③ (g) fixture 逐前缀证过【下一个号相等】,而 build.py 逐字节证过
--        【除了前缀字面量,别处一个字节都没动】。
--   ☞ 已知的界限,写在这里而不是藏着:(g) 证的是【下一个号】,不是并发取号。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ RLS:这张表必须【开 RLS 且 SELECT USING (true)】,而这一条闸抓不到 ★★
-- ════════════════════════════════════════════════════════════════════════════
--   9 支触发器铸码函数是 INVOKER(prosecdef=f,实测)。它们在生产上以
--   `authenticated` 跑。document_types 若没有一条 SELECT 策略,它们【读不到前缀】。
--   而 db/fixtures 以 postgres 跑 —— postgres 的 rolbypassrls=t,RLS 被绕过,
--   **fixture 会一路绿,生产上铸码全部失败。** 这是门【按构造】看不见的那一格。
--   ☞ 处置两条,都在这支迁移里:
--     · 策略 + 授权都写出来(默认权限已经给了 authenticated,写出来是为了让
--       重建那一侧与线上走同一段文本;anon 不在默认权限里,所以匿名面不变宽,
--       db/anon-grants-baseline.tsv 一行都不用动);
--     · ★ document_type_prefix() 读不到就【抛】,不返回 NULL。
--       这是这个仓库量过的那条:一个读返回值的判据,在 RLS 挡住的时候拿到的是
--       NULL 而不是拒绝 —— 于是 code 会变成 NULL,而不是变成一次响亮的失败。
--       (同 ALERT-1「被 RLS 挡下的 UPDATE 不是错误,是一次成功的空操作」。)
--   ☞ 而【验证】不许靠读策略然后自己同意自己:见 db/fixtures 与切次报告里
--     那次以 authenticated 真的跑过一遍的记录。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 44 支,不是 43
-- ════════════════════════════════════════════════════════════════════════════
--   六轮统计出的 43 支里,参数化那一支(fin_next_payment_code)本身没有字面量,
--   要改的是它的调用方。上一会话点了 record_payment:635,**漏了 reverse_payment:26
--   那一条一模一样的 CASE WHEN … 'RCPT' … 'PMT'**。
--   本支按【字面量住的那个空间】逐支扫过全部 public 函数,得到 44。
--   T1「任何前缀字面量不许活在种子之外」是裁定;这是把它应用完,不是重开它。
--
-- 生成:db/migrations/2026-09-13-search2b-document-types.build.py --emit
--   (函数体不是手打的。44 支合计 20 万字节,手打必然在某一支里顺手改掉别的东西,
--    而签名没变 + 镜像一起改 ⇒ 没有任何一道闸看得见。生成器自己断言
--    "把替换倒回去必须逐字节复原成原文"。)

BEGIN;

-- ── 表 ──────────────────────────────────────────────────────────────────────
-- 【安装种子 / INSTALL SEED】操作员在应用里改不了它,它与代码版本绑定 ⇒
-- check_mirrors.py 逐行比对线上。加一种单据是迁移级动作,天生如此。
CREATE TABLE public.document_types (
    key           text PRIMARY KEY,
    prefix        text NOT NULL UNIQUE,
    table_name    text NOT NULL,
    -- ★ T1:两套编号语义都留,存成这一列。收敛任何一边都会改掉那一边的输出,
    --   而那正是停止条件 (g)。'gapless' = MAX(split_part)+1(号码之间没有洞);
    --   'gapped'  = nextval(回滚不还号 —— 线上已经烧掉 1,177 个号,实测)。
    numbering     text NOT NULL CHECK (numbering IN ('gapless', 'gapped')),
    sequence_name text,
    route         text NOT NULL,
    link_mode     text NOT NULL CHECK (link_mode IN ('detail', 'list', 'list_q')),
    label_column  text,
    match_columns text[] NOT NULL DEFAULT '{}'::text[],
    -- 有洞的必须指名它那条序列;无洞的不许有 —— 一行自相矛盾的登记会让
    -- (g) 的期望值算在错的分支上,而那正是「suppliers 存着 0095、下一个是 0445」
    -- 那条实测要防的事。
    CONSTRAINT document_types_sequence_shape CHECK (
        (numbering = 'gapped'  AND sequence_name IS NOT NULL) OR
        (numbering = 'gapless' AND sequence_name IS NULL))
);

COMMENT ON TABLE public.document_types IS
    'SEARCH-2:这套系统能铸的单据种类。前缀是数据,不是字面量(T1)。'
    '定义的是【能铸什么】,不是【铸过什么】—— 8 张今天还没有行的表照样在册。';

ALTER TABLE public.document_types ENABLE ROW LEVEL SECURITY;

-- ★ 见抬头:没有这条策略,9 支 INVOKER 触发器在生产上读不到前缀,而 fixture
--   以 postgres 跑、rolbypassrls=t,一路绿。前缀不是秘密,读它没有门槛。
CREATE POLICY "document_types select by anyone signed in"
    ON public.document_types
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

-- 写:一条策略都不给 —— 与 permissions / tax_codes / wht_rates 同一类
--（它们也都只有 SELECT 策略,实测)。改它要走迁移。
GRANT SELECT ON public.document_types TO authenticated;

-- ── 前缀读取器 ──────────────────────────────────────────────────────────────
-- ★★ 读不到就【抛】,不返回 NULL ★★
--   返回 NULL 会让 'X' || NULL || '-' 整体变成 NULL,于是 code 变成 NULL ——
--   一次安静的错误,而不是一次响亮的失败。RLS 挡住读的那一刻正是这个函数
--   唯一有可能读不到的时刻,所以它必须在那里出声。
CREATE OR REPLACE FUNCTION public.document_type_prefix(p_key text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_prefix text;
BEGIN
    SELECT prefix INTO v_prefix FROM public.document_types WHERE key = p_key;
    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'DOCUMENT_TYPE_PREFIX_MISSING|%', p_key
            USING HINT = 'document_types 里没有这一行,或者当前角色读不到它'
                         '(RLS / GRANT)。铸码在此停下,而不是铸出一个 NULL 号。';
    END IF;
    RETURN v_prefix;
END;
$function$;

-- ── 40 行种子 ───────────────────────────────────────────────────────────────
-- 生成:db/migrations/2026-09-13-search2b-document-types.seed.py

INSERT INTO public.document_types
    (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns)
VALUES
    ('assay_result', 'ASY', 'assay_results', 'gapless', NULL, '/inbound', 'list_q', 'notes', ARRAY['lab_name', 'certificate_ref', 'sample_ref', 'notes']::text[]),
    ('collection_chase', 'CHASE', 'collection_chases', 'gapless', NULL, '/sales/customers', 'list_q', NULL, '{}'::text[]),
    ('cod', 'COD', 'certificates_of_destruction', 'gapless', NULL, '/output', 'list_q', 'void_reason', ARRAY['void_reason']::text[]),
    ('container', 'CTR', 'containers', 'gapless', NULL, '/logistics/containers', 'detail', 'notes', ARRAY['container_number', 'vessel', 'voyage', 'bl_number', 'notes']::text[]),
    ('credit_note', 'CN', 'credit_notes', 'gapless', NULL, '/finance/credit-notes', 'list', 'reason', ARRAY['reason']::text[]),
    ('employee', 'EMP', 'employees', 'gapless', NULL, '/hr/employees', 'detail', 'legal_name', ARRAY['legal_name', 'preferred_name', 'notes']::text[]),
    ('expense_claim', 'CLM', 'expense_claims', 'gapless', NULL, '/hr/claims', 'list', 'description', ARRAY['description', 'no_receipt_reason', 'decision_notes']::text[]),
    ('fixed_asset', 'FA', 'fixed_assets', 'gapless', NULL, '/finance/assets', 'detail', 'description', ARRAY['description', 'category', 'notes']::text[]),
    ('cash_forecast', 'FCST', 'cash_forecasts', 'gapless', NULL, '/finance/cash-forecast', 'list', NULL, '{}'::text[]),
    ('leave_request', 'LV', 'leave_requests', 'gapless', NULL, '/hr/leave', 'detail', 'reason', ARRAY['reason', 'certificate_ref', 'decision_notes']::text[]),
    ('medical_claim', 'MC', 'medical_claims', 'gapless', NULL, '/hr/claims', 'list', 'description', ARRAY['description', 'receipt_ref', 'decision_notes']::text[]),
    ('payroll_period', 'PAY', 'payroll_periods', 'gapless', NULL, '/hr/payroll', 'detail', 'notes', ARRAY['source_note', 'notes']::text[]),
    ('pricing_formula', 'PF', 'pricing_formulas', 'gapless', NULL, '/tools/pricing/formulas', 'list', 'name', ARRAY['name', 'notes']::text[]),
    ('purchase_order', 'PO', 'purchase_orders', 'gapless', NULL, '/purchasing/orders', 'detail', 'notes', ARRAY['terms_text', 'notes', 'delivery_location']::text[]),
    ('quote', 'QT', 'quotes', 'gapless', NULL, '/sales/quotes', 'detail', 'notes', ARRAY['terms_text', 'notes', 'decline_reason']::text[]),
    ('sales_order', 'SO', 'sales_orders', 'gapless', NULL, '/sales/orders', 'detail', 'notes', ARRAY['terms_text', 'notes', 'cancel_reason']::text[]),
    ('shipment', 'SHP', 'shipments', 'gapless', NULL, '/sales/shipments', 'detail', 'notes', ARRAY['notes']::text[]),
    ('customer_statement', 'STMT', 'customer_statements', 'gapless', NULL, '/sales/customers', 'list_q', NULL, '{}'::text[]),
    ('traceability_report', 'TRC', 'traceability_report_issues', 'gapless', NULL, '/output', 'list_q', NULL, '{}'::text[]),
    ('work_order', 'WO', 'work_orders', 'gapless', NULL, '/operation/orders', 'detail', 'notes', ARRAY['notes', 'close_reason']::text[]),
    ('contract', 'CON', 'contracts', 'gapped', 'contract_code_seq', '/contracts', 'list', NULL, '{}'::text[]),
    ('customer', 'CUS', 'customers', 'gapped', 'customer_code_seq', '/sales/customers', 'detail', 'legal_name', ARRAY['legal_name', 'short_name', 'address', 'country', 'tax_id', 'notes']::text[]),
    ('inbound_batch', 'IN', 'inbound_batches', 'gapped', 'inbound_code_seq', '/inbound', 'list_q', 'notes', ARRAY['notes', 'import_permit_ref', 'source_reason_note']::text[]),
    ('material', 'MAT', 'materials', 'gapped', 'material_code_seq', '/materials', 'list_q', 'name', ARRAY['name', 'chemistry', 'spec', 'notes']::text[]),
    ('output_batch', 'OUT', 'output_batches', 'gapped', 'output_code_seq', '/output', 'list_q', 'notes', ARRAY['purity', 'notes']::text[]),
    ('processing_run', 'PROC', 'processing_runs', 'gapped', 'processing_code_seq', '/operation/processing', 'detail', 'notes', ARRAY['notes']::text[]),
    ('stocktake', 'ST', 'stocktakes', 'gapped', 'stocktake_code_seq', '/stocktakes', 'detail', 'notes', ARRAY['notes']::text[]),
    ('supplier', 'SUP', 'suppliers', 'gapped', 'supplier_code_seq', '/suppliers', 'list_q', 'legal_name', ARRAY['legal_name', 'short_name', 'address', 'country', 'tax_id', 'notes']::text[]),
    ('task', 'TASK', 'tasks', 'gapped', 'task_code_seq', '/tools/tasks', 'detail', 'title', ARRAY['title', 'description']::text[]),
    ('invoice', 'INV', 'invoices', 'gapless', NULL, '/finance/invoices', 'detail', 'notes', ARRAY['notes', 'terms_text', 'void_reason']::text[]),
    ('management_pack', 'PACK', 'management_packs', 'gapless', NULL, '/finance/packs', 'detail', NULL, '{}'::text[]),
    ('bank_statement', 'BS', 'bank_statements', 'gapless', NULL, '/finance/bank/statements', 'detail', 'notes', ARRAY['file_name', 'notes']::text[]),
    ('attendance_period', 'ATT', 'attendance_periods', 'gapless', NULL, '/hr/attendance', 'list', NULL, '{}'::text[]),
    ('gst_period', 'GST', 'gst_periods', 'gapless', NULL, '/finance/gst', 'list', NULL, '{}'::text[]),
    ('journal_entry', 'JE', 'journal_entries', 'gapless', NULL, '/finance/journal', 'detail', 'memo', ARRAY['memo']::text[]),
    ('expense', 'EXP', 'expenses', 'gapless', NULL, '/finance/expenses', 'detail', 'notes', ARRAY['payee_name', 'notes']::text[]),
    ('freight_document', 'FRT', 'freight_documents', 'gapless', NULL, '/finance/freight', 'detail', 'notes', ARRAY['notes', 'reversal_reason']::text[]),
    ('wht_remittance', 'WHT', 'wht_remittances', 'gapless', NULL, '/finance/wht', 'list', NULL, '{}'::text[]),
    ('payment_receipt', 'RCPT', 'payments', 'gapless', NULL, '/finance/payments', 'detail', 'notes', ARRAY['notes']::text[]),
    ('payment_out', 'PMT', 'payments', 'gapless', NULL, '/finance/payments', 'detail', 'notes', ARRAY['notes']::text[]);

-- ════════════════════════════════════════════════════════════════════════════
-- 44 支函数体 —— 逐支只换掉它那一个前缀字面量,别处一个字节都没动
-- (生成器断言过:把替换倒回去,逐字节复原成线上现在的定义。)
-- ════════════════════════════════════════════════════════════════════════════

-- ── assign_contract_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assign_contract_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('contract') || '-' || to_char(COALESCE(NEW.effective_from, CURRENT_DATE), 'YYYY')
                    || '-' || lpad(nextval('public.contract_code_seq')::text, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- ── create_invoice ──────────────────────────────────────────────────────
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
$function$;

-- ── create_order_invoice ──────────────────────────────────────────────────────
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
$function$;

-- ── freeze_management_pack ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.freeze_management_pack(p_period_month date, p_notes text DEFAULT NULL::text, p_supersede_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start   date;
    v_end     date;
    v_locked  date;
    v_base    text;
    v_prev    management_packs%ROWTYPE;
    v_reason  text;
    v_payload jsonb;
    v_seq     integer;
    v_code    text;
    v_id      uuid := gen_random_uuid();
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】一支不问的 definer 函数就是一条
    -- 绕过 RLS 的路;这个形状在本仓库上线过两次、两次都由闸抓住。
    -- 产出是一次写,所以要 edit;而 payload 来自只要 view 的那支函数。
    PERFORM require_permission('module.finance.edit');
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_period_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;

    SELECT locked_before INTO v_locked FROM finance_settings;
    -- ★ 本刀的裁定,按名拒并把两个日期都说出来 —— 一条只说"不行"的拒绝
    --   会让人去猜是哪一天挡着。
    IF v_locked IS NULL OR v_locked <= v_end THEN
        RAISE EXCEPTION 'PACK_MONTH_NOT_LOCKED|%|%', to_char(v_start, 'YYYY-MM'),
            COALESCE(v_locked::text, '—')
          USING HINT = '只有已关账的月份才冻得下来 —— 开放月份看得到实时预览、也导得出 CSV,但那不是一份可以存档的包;先在月结那一步关账';
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 已有在册的一份?那就要说出为什么再出一份。
    SELECT * INTO v_prev FROM management_packs
     WHERE period_month = v_start AND superseded_at IS NULL;
    IF FOUND THEN
        v_reason := NULLIF(btrim(COALESCE(p_supersede_reason, '')), '');
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'PACK_SUPERSEDE_REASON_REQUIRED|%', v_prev.code
              USING HINT = '这个月已经有一份在册的包 —— 再出一份要说明为什么(重开期间补记了什么?哪个数变了?)';
        END IF;
    END IF;

    -- 【payload 是调用来的,不是算来的】
    v_payload := management_pack_data(v_start);

    -- 编号:同一个月可以有多份(重出),第二份起带序号。
    -- 咨询锁串行化,与 EXP/JE/收付款/汇缴的取号手法一致。
    PERFORM pg_advisory_xact_lock(hashtext('mgmt_pack_' || to_char(v_start, 'YYYY-MM'))::bigint);
    SELECT COUNT(*) + 1 INTO v_seq FROM management_packs WHERE period_month = v_start;
    v_code := document_type_prefix('management_pack') || '-' || to_char(v_start, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    -- ★【旧的那一份必须【先】落 superseded,而这是探针当场抓到的】★
    --   idx_management_packs_live_month 是一条【部分唯一索引】
    --   ((period_month) WHERE superseded_at IS NULL)—— 一个月只许有一份在册。
    --   所以"先插新的、再标旧的"会撞唯一约束:那一瞬间同一个月有两份在册。
    --   顺序反过来就没有那一瞬间。指向新行不需要等它写下来 ——
    --   v_id 是【预先生成】的,与 record_payment / record_expense 让分录先行、
    --   单据带着链接一次到位是同一个手法。
    IF v_prev.id IS NOT NULL THEN
        UPDATE management_packs
           SET superseded_at = now(), superseded_by = v_id, superseded_reason = v_reason
         WHERE id = v_prev.id;
    END IF;

    INSERT INTO management_packs (id, code, period_month, period_start, period_end,
                                  locked_before_at_production, base_currency, payload,
                                  notes, produced_by)
    VALUES (v_id, v_code, v_start, v_start, v_end,
            v_locked, v_base, v_payload, p_notes, auth.uid());

    RETURN jsonb_build_object(
        'pack_id',      v_id,
        'code',         v_code,
        'period_month', v_start,
        'period_end',   v_end,
        'locked_before_at_production', v_locked,
        'superseded',   v_prev.code);
END;
$function$;

-- ── generate_customer_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_customer_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('customer') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('customer_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- ── generate_inbound_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_inbound_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('inbound_batch') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('inbound_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- ── generate_material_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_material_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('material') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('material_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- ── generate_output_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_output_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('output_batch') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('output_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- ── generate_processing_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_processing_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('processing_run') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('processing_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- ── generate_stocktake_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_stocktake_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('stocktake') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('stocktake_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- ── generate_supplier_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_supplier_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.code IS NULL OR NEW.code = '' THEN
    NEW.code := document_type_prefix('supplier') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                LPAD(nextval('supplier_code_seq')::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$function$;

-- ── generate_task_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_task_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := document_type_prefix('task') || '-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('task_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- ── import_bank_statement ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.import_bank_statement(p_bank_account text, p_period_start date, p_period_end date, p_opening numeric, p_closing numeric, p_file_name text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ccy          text;
    v_statement_id uuid := gen_random_uuid();
    v_year         integer;
    v_seq          integer;
    v_code         text;
    v_line         jsonb;
    v_no           integer := 0;
    v_amount       numeric;
    v_date         date;
    v_sum          numeric := 0;
    v_overlaps     integer;
    v_dups         integer := 0;
BEGIN
    PERFORM require_permission('module.finance.edit');
    v_ccy := bank_native_currency(p_bank_account);
    IF v_ccy IS NULL THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_bank_account, '?');
    END IF;
    IF p_period_start IS NULL OR p_period_end IS NULL OR p_period_end < p_period_start THEN
        RAISE EXCEPTION 'PERIOD_INVALID|%|%', COALESCE(p_period_start::text,'?'), COALESCE(p_period_end::text,'?');
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- 先整体校验(金额为非零数字、日期在期间内)并求 Σ
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_no := v_no + 1;
        IF jsonb_typeof(v_line->'amount') <> 'number' OR (v_line->>'amount')::numeric = 0 THEN
            RAISE EXCEPTION 'LINE_AMOUNT_INVALID|%', v_no;
        END IF;
        v_amount := (v_line->>'amount')::numeric;
        v_date := (v_line->>'line_date')::date;
        IF v_date IS NULL OR v_date < p_period_start OR v_date > p_period_end THEN
            RAISE EXCEPTION 'LINE_DATE_OUT_OF_RANGE|%|%', v_no, COALESCE(v_date::text, '?');
        END IF;
        v_sum := v_sum + v_amount;

        -- 疑似重复(同账户其他在册报表上已有同日期+同金额+同摘要的行)—— 只计数
        SELECT v_dups + count(*) INTO v_dups
        FROM bank_statement_lines l
        JOIN bank_statements s ON s.id = l.statement_id
        WHERE s.bank_account_code = p_bank_account
          AND s.deleted_at IS NULL
          AND l.line_date = v_date
          AND l.amount = v_amount
          AND l.description IS NOT DISTINCT FROM (v_line->>'description');
    END LOOP;

    -- 余额恒等式:opening + Σ = closing
    IF round(p_opening + v_sum, 2) IS DISTINCT FROM round(p_closing, 2) THEN
        RAISE EXCEPTION 'STATEMENT_NOT_BALANCED|%|%', round(p_opening + v_sum, 2), round(p_closing, 2);
    END IF;

    -- 期间重叠警告(不拦)
    SELECT count(*) INTO v_overlaps
    FROM bank_statements s
    WHERE s.bank_account_code = p_bank_account
      AND s.deleted_at IS NULL
      AND s.period_start <= p_period_end
      AND s.period_end >= p_period_start;

    -- 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款/开支手法)
    v_year := EXTRACT(YEAR FROM p_period_end)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('bank_stmt_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM bank_statements
    WHERE code LIKE document_type_prefix('bank_statement') || '-' || v_year::text || '-%';
    v_code := document_type_prefix('bank_statement') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO bank_statements (id, code, bank_account_code, currency, period_start, period_end,
                                 opening_balance, closing_balance, file_name)
    VALUES (v_statement_id, v_code, p_bank_account, v_ccy, p_period_start, p_period_end,
            p_opening, p_closing, p_file_name);

    -- 行按数组顺序编号
    v_no := 0;
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_no := v_no + 1;
        INSERT INTO bank_statement_lines (statement_id, line_no, line_date, description, reference, amount)
        VALUES (v_statement_id, v_no, (v_line->>'line_date')::date,
                v_line->>'description', v_line->>'reference', (v_line->>'amount')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'statement_id', v_statement_id,
        'code', v_code,
        'line_count', v_no,
        'overlapping_statements', v_overlaps,
        'possible_duplicates', v_dups
    );
END;
$function$;

-- ── next_assay_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_assay_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('assay_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM assay_results
    WHERE code LIKE document_type_prefix('assay_result') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('assay_result') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_chase_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_chase_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 自己的一把锁 —— 共用一把会烧掉别人的号,而无缝的意思正是号码之间没有洞。
    PERFORM pg_advisory_xact_lock(hashtext('chase_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM collection_chases
     WHERE code LIKE document_type_prefix('collection_chase') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('collection_chase') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_cod_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_cod_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】与 next_traceability_report_code / next_credit_note_code
    -- 逐字同一套:共用一把锁会让一种单据烧掉另一种的号,而无缝的意思正是
    -- "号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('cod_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM certificates_of_destruction
    WHERE code LIKE document_type_prefix('cod') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('cod') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_container_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_container_code(p_date date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_year integer; v_seq integer;
BEGIN
    -- 与 next_shipment_code 一字不差的形状:互斥点是 advisory key 这个字符串,
    -- MAX+1 只是推导;两个并发调用靠这把锁串行,回滚即释放号码。
    v_year := EXTRACT(YEAR FROM p_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('container_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM containers WHERE code LIKE document_type_prefix('container') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('container') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_credit_note_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_credit_note_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁,而不是跟发票共用 'invoice_code_<year>'】两种单据各自
    -- 连号:CN-2026-0001 与 INV-2026-0001 是两个序列。共用一把锁会让贷项凭证
    -- 烧掉发票的号(反过来也一样),而无缝的意思正是"号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('credit_note_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM credit_notes
    WHERE code LIKE document_type_prefix('credit_note') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('credit_note') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_employee_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_employee_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('employee_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM employees
    WHERE code LIKE document_type_prefix('employee') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('employee') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_expense_claim_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_expense_claim_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('expense_claim_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM expense_claims WHERE code LIKE document_type_prefix('expense_claim') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('expense_claim') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_fixed_asset_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_fixed_asset_code(p_on date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_on)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('fixed_asset_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(fa.code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM fixed_assets fa
    WHERE fa.code LIKE document_type_prefix('fixed_asset') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('fixed_asset') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_forecast_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_forecast_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('forecast_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM cash_forecasts WHERE code LIKE document_type_prefix('cash_forecast') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('cash_forecast') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_leave_request_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_leave_request_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('leave_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM leave_requests WHERE code LIKE document_type_prefix('leave_request') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('leave_request') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_medical_claim_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_medical_claim_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('medical_claim_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM medical_claims WHERE code LIKE document_type_prefix('medical_claim') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('medical_claim') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_payroll_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_payroll_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('payroll_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM payroll_periods
    WHERE code LIKE document_type_prefix('payroll_period') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('payroll_period') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_pricing_formula_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_pricing_formula_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('pricing_formula_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM pricing_formulas
    WHERE code LIKE document_type_prefix('pricing_formula') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('pricing_formula') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_purchase_order_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_purchase_order_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('purchase_order_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM purchase_orders
    WHERE code LIKE document_type_prefix('purchase_order') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('purchase_order') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_quote_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_quote_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】QT 与 SO / INV / CN 各自连号 —— 共用一把会让一种单据
    -- 烧掉另一种的号,而无缝的意思正是"号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('quote_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM quotes
    WHERE code LIKE document_type_prefix('quote') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('quote') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_sales_order_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_sales_order_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('sales_order_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM sales_orders
    WHERE code LIKE document_type_prefix('sales_order') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('sales_order') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_shipment_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_shipment_code(p_date date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer;
    v_seq  integer;
BEGIN
    -- 【无缝编号,自己的那把锁】互斥点是 advisory key 这个字符串 ——
    -- 'shipment_code_<year>',与发票('invoice_code_')、销售订单各自一把。
    -- MAX+1 只是推导;两个并发调用靠这把锁串行,回滚即释放号码。
    v_year := EXTRACT(YEAR FROM p_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('shipment_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM shipments WHERE code LIKE document_type_prefix('shipment') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('shipment') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_statement_code ──────────────────────────────────────────────────────
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
     WHERE code LIKE document_type_prefix('customer_statement') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('customer_statement') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_traceability_report_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_traceability_report_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】与 next_credit_note_code / next_shipment_code / next_quote_code
    -- 逐字同一套:共用一把锁会让一种单据烧掉另一种的号,而无缝的意思正是
    -- "号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('traceability_report_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM traceability_report_issues
    WHERE code LIKE document_type_prefix('traceability_report') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('traceability_report') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── next_work_order_code ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_work_order_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】WO 与 SO / QT / CN 各自连号 —— 共用一把会让一种单据
    -- 烧掉另一种的号,而无缝的意思正是"号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('work_order_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM work_orders
    WHERE code LIKE document_type_prefix('work_order') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('work_order') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ── open_attendance_period ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.open_attendance_period(p_period_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_m date; v_id uuid; v_code text; v_n int;
BEGIN
    PERFORM require_permission('module.hr.edit');
    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'ATTENDANCE_MONTH_REQUIRED';
    END IF;
    v_m := date_trunc('month', p_period_month)::date;
    -- 【还没过完的月份不开】一个月的考勤在它结束之前不可能是完整的,
    -- 而这张底稿存在的意义就是"完整"这句断言。
    IF v_m > date_trunc('month', CURRENT_DATE)::date THEN
        RAISE EXCEPTION 'ATTENDANCE_MONTH_FUTURE|%|%', v_m::text, CURRENT_DATE::text;
    END IF;
    IF EXISTS (SELECT 1 FROM attendance_periods WHERE period_month = v_m) THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_EXISTS|%',
            (SELECT code FROM attendance_periods WHERE period_month = v_m);
    END IF;

    v_code := document_type_prefix('attendance_period') || '-' || to_char(v_m, 'YYYY-MM');
    INSERT INTO attendance_periods (code, period_month, opened_by)
    VALUES (v_code, v_m, auth.uid()) RETURNING id INTO v_id;

    -- 【每一个在这个月里在册过的人都铺一行】—— 见抬头 §4:
    -- 只给"有加班的人"建行,会让"没建行"同时意味着"没有加班"和"忘了",
    -- 而那正是这一刀要拆开的两件事。
    INSERT INTO attendance_lines (period_id, employee_id)
    SELECT v_id, e.id FROM employees e
     WHERE e.deleted_at IS NULL
       AND e.hire_date <= (v_m + interval '1 month - 1 day')::date
       AND (e.separation_date IS NULL OR e.separation_date >= v_m);
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('period_id', v_id, 'code', v_code,
                              'period_month', v_m, 'lines', v_n);
END;
$function$;

-- ── open_gst_period ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.open_gst_period(p_period_start date, p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_code text; v_id uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'GST_PERIOD_DATES_REQUIRED';
    END IF;
    -- 【季度的形状】新加坡的标准申报周期是一个季;要按月/按半年是另一回事,
    -- 到时候由 IRAS 的批准决定,不由这里猜。
    IF p_period_start <> date_trunc('quarter', p_period_start)::date
       OR p_period_end <> (date_trunc('quarter', p_period_start) + interval '3 months - 1 day')::date THEN
        RAISE EXCEPTION 'GST_PERIOD_NOT_A_QUARTER|%|%', p_period_start, p_period_end;
    END IF;
    IF EXISTS (SELECT 1 FROM gst_periods WHERE period_start = p_period_start AND corrects_period_id IS NULL) THEN
        RAISE EXCEPTION 'GST_PERIOD_EXISTS|%', p_period_start;
    END IF;
    v_code := document_type_prefix('gst_period') || '-' || to_char(p_period_start,'YYYY') || '-Q'
              || EXTRACT(quarter FROM p_period_start)::text;
    INSERT INTO gst_periods (code, period_start, period_end, status)
    VALUES (v_code, p_period_start, p_period_end, 'open') RETURNING id INTO v_id;
    RETURN jsonb_build_object('gst_period_id', v_id, 'code', v_code,
                              'period_start', p_period_start, 'period_end', p_period_end);
END;
$function$;

-- ── post_journal_entry ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.post_journal_entry(p_entry_date date, p_memo text, p_source_type text, p_source_id uuid, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_line         jsonb;
    v_account      record;
    v_side         text;
    v_currency     text;
    v_amount       numeric;
    v_fx           numeric;
    v_usd          numeric;
    v_fx_date      date;
    v_base         text;
    v_total_debit  numeric := 0;
    v_total_credit numeric := 0;
    v_count        integer := 0;
    v_year         integer;
    v_seq          integer;
    v_code         text;
    v_entry_id     uuid;
    v_tax_code     text;
BEGIN
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    IF p_entry_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 过账许可:年结闸与期间锁 —— ASY-1 起【搬进 assert_posting_allowed】,
    -- 与只读试算共用一份,预览因此不会放行一笔提交会拒的分录。闸的文字、次序、
    -- close_ctx 例外原样搬走,这里只剩调用。
    PERFORM assert_posting_allowed(p_entry_date, p_source_type);

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|lines';
    END IF;

    -- 无缝编号:咨询锁串行化"取当年最大号+1";失败回滚会释放号码。
    PERFORM pg_advisory_xact_lock(hashtext('je_code')::bigint);
    v_year := EXTRACT(YEAR FROM p_entry_date)::integer;
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM journal_entries
    WHERE code LIKE document_type_prefix('journal_entry') || '-' || v_year::text || '-%';
    v_code := document_type_prefix('journal_entry') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO journal_entries (code, entry_date, memo, source_type, source_id)
    VALUES (v_code, p_entry_date, p_memo, p_source_type, p_source_id)
    RETURNING id INTO v_entry_id;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;

        SELECT id, code, is_active INTO v_account
        FROM accounts WHERE code = v_line->>'account_code';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(v_line->>'account_code', '?');
        END IF;
        IF NOT v_account.is_active THEN
            RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code;
        END IF;

        v_side := v_line->>'side';
        -- GST-1:这一行在 GST 上算什么。**绝大多数行没有税码,那是对的。**
        v_tax_code := NULLIF(v_line->>'tax_code', '');
        IF v_tax_code IS NOT NULL THEN
            -- 【没注册就不许盖税码】这一句把"开关关着 = 与今天一模一样"从一句
            -- 断言变成一条【写不进去】的规矩:未注册时根本产生不了带税码的行。
            IF NOT gst_registered() THEN
                RAISE EXCEPTION 'GST_NOT_REGISTERED|%', v_tax_code;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM tax_codes WHERE code = v_tax_code AND is_active) THEN
                RAISE EXCEPTION 'TAX_CODE_UNKNOWN|%', v_tax_code;
            END IF;
            -- 【解析一次税率,只为了让"那一天没有税率"当场被拒】
            -- 不存下来:税额本身由分录行自己表达,存第二份就是两处陈述同一件事。
            PERFORM tax_rate_for(v_tax_code, p_entry_date);
        END IF;
        IF v_side IS NULL OR v_side NOT IN ('debit', 'credit') THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|side';
        END IF;

        v_amount := (v_line->>'amount_ccy')::numeric;
        IF v_amount IS NULL OR v_amount <= 0 THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|amount_ccy';
        END IF;

        v_currency := v_line->>'currency';
        IF v_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = v_currency) THEN
            RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(v_currency, '?');
        END IF;

        v_fx_date := NULLIF(v_line->>'fx_rate_date', '')::date;
        IF v_currency = v_base THEN
            v_fx := 1;
            v_fx_date := NULL;  -- 本位币没有取自哪天这回事  -- 本位币(FIN-0 起为 SGD)强制 1,忽略传入值
        ELSE
            v_fx := (v_line->>'fx_rate')::numeric;
            IF v_fx IS NULL THEN
                RAISE EXCEPTION 'FX_RATE_REQUIRED|%', v_currency;
            END IF;
            IF v_fx <= 0 THEN
                RAISE EXCEPTION 'JE_LINE_INVALID|fx_rate';
            END IF;
        END IF;

        v_usd := round(v_amount * v_fx, 2);

        INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate, fx_rate_date, line_memo, tax_code)
        VALUES (
            v_entry_id,
            v_account.id,
            CASE WHEN v_side = 'debit'  THEN v_usd ELSE 0 END,
            CASE WHEN v_side = 'credit' THEN v_usd ELSE 0 END,
            v_currency,
            v_amount,
            v_fx,
            v_fx_date,
            v_line->>'line_memo',
            v_tax_code
        );

        IF v_side = 'debit' THEN
            v_total_debit := v_total_debit + v_usd;
        ELSE
            v_total_credit := v_total_credit + v_usd;
        END IF;
    END LOOP;

    -- 空数组/单行:延迟触发器只在有行插入时排队,这里提前拦掉(否则空分录溜过)
    IF v_count < 2 THEN
        RAISE EXCEPTION 'JOURNAL_UNBALANCED|%|%|%', v_code, v_total_debit, v_total_credit;
    END IF;

    -- Σdebit = Σcredit 由 DEFERRED 触发器在提交时强制
    RETURN jsonb_build_object(
        'entry_id', v_entry_id,
        'code', v_code,
        'total_debit', v_total_debit,
        'total_credit', v_total_credit
    );
END;
$function$;

-- ── record_expense ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid, p_tax_code text DEFAULT NULL::text, p_wht_nature text DEFAULT NULL::text, p_wht_rate_pct numeric DEFAULT NULL::numeric, p_wht_treaty_ref text DEFAULT NULL::text, p_maintenance_id uuid DEFAULT NULL::uuid)
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
$function$;

-- ── record_export_freight_document ──────────────────────────────────────────────────────
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

    -- ── 必填项,与进料侧同一条规矩(FIN-10):日期决定期间与汇率,绝不默认 ────
    IF p_doc_date IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_DATE_REQUIRED';
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

-- ── record_freight_document ──────────────────────────────────────────────────────
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

    -- ── 必填项:日期决定期间与汇率,绝不默认(FIN-10)────────────────────────
    IF p_doc_date IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_DATE_REQUIRED';
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

-- ── record_payment ──────────────────────────────────────────────────────
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
            SELECT e.id, e.code AS doc_code, COALESCE(e.supplier_id, e.employee_id) AS party_id,
                   e.amount_ccy AS doc_value, e.currency AS doc_ccy, e.fx_rate AS doc_fx,
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
$function$;

-- ── relieve_processing_accruals ──────────────────────────────────────────────────────
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

-- ── remit_wht ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.remit_wht(p_period_month date, p_remitted_on date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_month   date;
    v_amount  numeric;
    v_bank    text;
    v_base    text;
    v_ref     text;
    v_seq     integer;
    v_code    text;
    v_je      jsonb;
    v_id      uuid := gen_random_uuid();
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】一支不问的 definer 函数就是一条
    -- 绕过 RLS 的路。这个形状在本仓库【上线过两次、被闸抓住两次】——
    -- 写在这里是因为下一支新函数最容易漏的就是这一行。
    PERFORM require_permission('module.finance.edit');
    -- fu1:**也要求 view,而这条依赖是说出来的、不是碰巧成立的。**
    -- 本函数从 wht_liability_by_month 读欠款,而 fu1 起那张视图按
    -- module.finance.view 把关。不写这一句,一个持 edit 而不持 view 的角色
    -- 会读到一张空视图,然后撞上 WHT_NOTHING_TO_REMIT —— 一句【说错了原因】的
    -- 拒绝:它会说"这个月没有欠款",而真相是"你看不见它"。
    -- (实测 2026-08-28:线上三个持 edit 的角色 admin/gm/finance 都持 view,
    --  所以这一句今天不改变任何人的结果 —— 它防的是下一次配角色的人。)
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'WHT_PERIOD_REQUIRED';
    END IF;
    v_month := date_trunc('month', p_period_month)::date;

    IF p_remitted_on IS NULL THEN
        RAISE EXCEPTION 'WHT_REMIT_DATE_REQUIRED|%', v_month;
    END IF;
    IF p_remitted_on < v_month THEN
        -- 还没发生的代扣汇不出去。
        RAISE EXCEPTION 'WHT_REMIT_DATE_BEFORE_PERIOD|%|%', p_remitted_on, v_month;
    END IF;

    -- 【参考号必填,而 gst_periods 那一条允许空 —— 两者不是同一件事】
    -- GST 那边"申报"与"缴款"是两个动作,回执可能晚到;这里是【一次缴款】,
    -- 而一笔说不出参考号的缴款,日后对着 IRAS 无从交代。
    v_ref := NULLIF(btrim(COALESCE(p_filed_reference, '')), '');
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'WHT_FILED_REFERENCE_REQUIRED|%', v_month
          USING HINT = '填 IRAS S45 申报的回执/参考号 —— 一笔交代不出出处的缴款,日后无从对账';
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 【银行必须是本位币户,而这一条【故意】比 pay_payroll_cpf 严】
    -- IRAS 只收新元。pay_payroll_cpf 允许 1010 却把两条腿都按本位币记 ——
    -- 那意味着一笔从美元户走的钱会被记成等额新元离开,而实际离开的是美元。
    -- 那一支不在本刀范围内(不顺手改别人的函数),但这一支不复制它。
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    IF bank_native_currency(v_bank) <> v_base THEN
        RAISE EXCEPTION 'WHT_REMIT_BANK_NOT_BASE|%|%', v_bank, bank_native_currency(v_bank)
          USING HINT = 'IRAS 只收本位币 —— 从外币户汇出去要先兑换,而那笔兑换是它自己的一笔交易';
    END IF;

    -- 【欠多少从那张视图读,不在这里再算一遍】视图是唯一的实现,而它对
    -- 冲销的处理(经 journal_activity_lines)是这条链上最容易写错的一段。
    -- 在这里重算 = 第二份实现,而两份会在写下来那天一致、之后悄悄分开。
    SELECT unremitted_base INTO v_amount
    FROM wht_liability_by_month WHERE period_month = v_month;

    IF COALESCE(v_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'WHT_NOTHING_TO_REMIT|%|%', v_month, COALESCE(v_amount, 0)
          USING HINT = '这个月没有未汇的代扣税 —— 也可能是已经汇过了(补汇是新的一行,不是改旧的那一行)';
    END IF;

    -- 分录走【普通过账路径】,所以期间锁照常生效 —— 与 CPF 同一条:
    -- 一笔汇款不因为它是法定义务就可以进一个已经关掉的月份。
    v_je := post_journal_entry(
        p_remitted_on,
        'Withholding tax remittance ' || to_char(v_month, 'YYYY-MM'),
        'wht_remittance', v_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2150', 'side', 'debit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'WHT for ' || to_char(v_month, 'YYYY-MM')),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'IRAS ' || v_ref)));

    -- 编号:同一个月可以有多笔(补汇),第二笔起带序号。
    -- 咨询锁串行化,与 EXP/JE/收付款的取号手法一致。
    PERFORM pg_advisory_xact_lock(hashtext('wht_remit_' || to_char(v_month, 'YYYY-MM'))::bigint);
    SELECT COUNT(*) + 1 INTO v_seq FROM wht_remittances WHERE period_month = v_month;
    v_code := document_type_prefix('wht_remittance') || '-' || to_char(v_month, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    INSERT INTO wht_remittances (id, code, period_month, remitted_on, amount_base,
                                 filed_reference, journal_entry_id, notes, created_by)
    VALUES (v_id, v_code, v_month, p_remitted_on, v_amount,
            v_ref, (v_je->>'entry_id')::uuid, p_notes, auth.uid());

    RETURN jsonb_build_object(
        'remittance_id', v_id,
        'code', v_code,
        'period_month', v_month,
        'remitted_on', p_remitted_on,
        'amount_base', v_amount,
        'currency', v_base,
        'filed_reference', v_ref,
        'journal_code', v_je->>'code');
END;
$function$;

-- ── reverse_expense ──────────────────────────────────────────────────────
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
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, CURRENT_DATE, 'Expense reversal ' || v_orig.code);

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

-- ── reverse_payment ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reverse_payment(p_payment_id uuid, p_memo text DEFAULT NULL::text)
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
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_orig FROM payments WHERE id = p_payment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND|%', p_payment_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_payment IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, CURRENT_DATE, 'Payment reversal ' || v_orig.code);

    -- 镜像收付款单(现金退回),挂冲销分录,不带核销行
    v_mirror_code := fin_next_payment_code(CASE WHEN v_orig.direction = 'in' THEN document_type_prefix('payment_receipt') ELSE document_type_prefix('payment_out') END, CURRENT_DATE);

    -- SOD-1:告诉 guard_payment_sod 这是一次【冲销】,不是一次付款。
    PERFORM set_config('evoltrya.payment_reversal_ctx', '1', true);
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, v_orig.direction, v_orig.counterparty_type,
            v_orig.customer_id, v_orig.supplier_id,
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

COMMIT;
