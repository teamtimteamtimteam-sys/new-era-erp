-- db/migrations/2026-07-31-phase4-cut2a-invoices.sql
-- Phase 4 cut 2a: customer invoices (DB only).
--
-- DESIGN: 收入与应收【在销售当刻就已确认】—— record_output_sale 已经过了收入与
-- COGS 分录,并写下 sales_records 行(那一行本身就是 AR 单据)。因此发票【不过任何
-- 分录】:它只是把同一个客户名下若干张已存在的 sales_records 归拢成一份可以寄出去
-- 的文件。收付款照旧核销到 sales_records;发票的已结/未结由其明细行背后的
-- sales_records 推导。于是本切是纯增量的:record_output_sale、record_payment、
-- AR 结算口径、任何分录逻辑,一律未改。
--
-- GST:公司尚未做 GST 登记。本切把字段与设置开关先建好,让"登记"变成改设置而不是
-- 改表结构,但【不过任何税金分录】。把 GST 接进分录属于后续切次,而且【正确的入账
-- 时点是销售那一刻,不是开票那一刻】—— 收入既然在销售时确认,销项税也应当在销售时
-- 确认;发票只是事后归拢,不该成为税的确认点。
--
-- Pieces:
--   B1. finance_settings + GST 三列;customers + payment_terms_days
--   B2. invoices(不可变,只允许 issued→void)
--   B3. invoice_lines(不可变)+ "一张销售只能挂一张在册发票"的硬约束
--   B4. create_invoice()
--   B5. void_invoice()
--   B6. view invoice_status
--   B7. ar_open_items 增加 invoice_id / invoice_code(DROP+CREATE)

BEGIN;

-- ============================================================================
-- B1. 设置与客户账期
-- ============================================================================
ALTER TABLE public.finance_settings
    ADD COLUMN gst_registered boolean NOT NULL DEFAULT false,
    ADD COLUMN gst_rate_pct numeric NOT NULL DEFAULT 0
        CHECK (gst_rate_pct >= 0 AND gst_rate_pct <= 100),
    ADD COLUMN gst_registration_no text;

-- 既有的 payment_terms 是自由文本(诸如 "30 days from B/L"),保持原样不动;
-- 新列是机器可读的账期天数,用来算 due_date。
ALTER TABLE public.customers
    ADD COLUMN payment_terms_days integer
        CHECK (payment_terms_days IS NULL OR payment_terms_days BETWEEN 0 AND 365);

-- ============================================================================
-- B2. invoices
-- 已开出的发票不可变:更正靠"作废 + 重开",不靠改字段。故无 updated_at/deleted_at。
-- ============================================================================
CREATE TABLE public.invoices (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code               text NOT NULL UNIQUE,  -- gapless 'INV-YYYY-NNNN',create_invoice 按 issue_date 年份分配
    customer_id        uuid NOT NULL REFERENCES public.customers (id),
    issue_date         date NOT NULL,
    due_date           date NOT NULL,
    payment_terms_days integer NOT NULL CHECK (payment_terms_days >= 0),
    currency           text NOT NULL REFERENCES public.currencies (code),
    subtotal_usd       numeric NOT NULL,
    tax_rate_pct       numeric NOT NULL DEFAULT 0,
    tax_usd            numeric NOT NULL DEFAULT 0,
    total_usd          numeric NOT NULL,
    status             text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued','void')),
    void_reason        text,
    voided_at          timestamptz,
    voided_by          uuid,
    notes              text,
    terms_text         text,
    -- 开票当刻客户抬头的快照(列取自 customers 实际存在的字段:
    -- code / legal_name / short_name / country / tax_id / address / payment_terms / incoterm)。
    -- 客户资料日后改了,几年后重打这张发票仍然显示当时寄出去的内容。
    bill_to_snapshot   jsonb NOT NULL,
    created_at         timestamptz DEFAULT now(),
    created_by         uuid DEFAULT auth.uid()
);

CREATE INDEX idx_invoices_customer ON public.invoices (customer_id);
CREATE INDEX idx_invoices_issue_date ON public.invoices (issue_date);

-- 守卫:只放行 issued→void(连同 void_reason/voided_at/voided_by),其余列逐列锁死
CREATE OR REPLACE FUNCTION public.guard_invoice_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    IF NEW.id                 IS DISTINCT FROM OLD.id
       OR NEW.code               IS DISTINCT FROM OLD.code
       OR NEW.customer_id        IS DISTINCT FROM OLD.customer_id
       OR NEW.issue_date         IS DISTINCT FROM OLD.issue_date
       OR NEW.due_date           IS DISTINCT FROM OLD.due_date
       OR NEW.payment_terms_days IS DISTINCT FROM OLD.payment_terms_days
       OR NEW.currency           IS DISTINCT FROM OLD.currency
       OR NEW.subtotal_usd       IS DISTINCT FROM OLD.subtotal_usd
       OR NEW.tax_rate_pct       IS DISTINCT FROM OLD.tax_rate_pct
       OR NEW.tax_usd            IS DISTINCT FROM OLD.tax_usd
       OR NEW.total_usd          IS DISTINCT FROM OLD.total_usd
       OR NEW.notes              IS DISTINCT FROM OLD.notes
       OR NEW.terms_text         IS DISTINCT FROM OLD.terms_text
       OR NEW.bill_to_snapshot   IS DISTINCT FROM OLD.bill_to_snapshot
       OR NEW.created_at         IS DISTINCT FROM OLD.created_at
       OR NEW.created_by         IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    IF NOT (OLD.status = 'issued' AND NEW.status = 'void'
            AND OLD.voided_at IS NULL AND NEW.voided_at IS NOT NULL) THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_invoices_immutable
    BEFORE UPDATE OR DELETE ON public.invoices
    FOR EACH ROW EXECUTE FUNCTION public.guard_invoice_mutation();

ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on invoices"
    ON public.invoices FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on invoices"
    ON public.invoices FOR INSERT TO authenticated WITH CHECK (true);
-- 窄用途 UPDATE 策略:仅为作废路径放行;允许改哪些列由上面的守卫触发器执行。
CREATE POLICY "authenticated void on invoices"
    ON public.invoices FOR UPDATE TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B3. invoice_lines
--
-- "一张销售只能挂在一张【在册】发票上,作废后可以重开" —— 这个约束怎么落地:
-- 部分唯一索引的 WHERE 子句不能引用另一张表(void 状态在 invoices 上),所以
-- 单靠 invoice_lines 上的部分唯一索引做不到。这里【两条腿一起用】:
--   1) 冗余一列 invoice_voided,由 invoices 上的 AFTER UPDATE 触发器自动同步
--      (作废是唯一会改它的路径,所以不会漂移),再对它建部分唯一索引 ——
--      这是【硬保证】,并发下也不会出现同一张销售挂上两张在册发票(重复开票
--      给客户是真实的账务事故,值得一个索引级的保证,而不是"检查后再插入"
--      那种存在竞态窗口的写法)。
--   2) create_invoice 里先做一次友好检查,抛 'ALREADY_INVOICED|sale_code|invoice_code'
--      —— 让用户看到"这张销售已在 INV-xxxx 上",而不是一条原始的唯一约束报错。
-- 索引负责正确性,函数检查负责可读性。
-- ============================================================================
CREATE TABLE public.invoice_lines (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id      uuid NOT NULL REFERENCES public.invoices (id) ON DELETE RESTRICT,
    sales_record_id uuid NOT NULL REFERENCES public.sales_records (id),
    line_no         integer NOT NULL,
    description     text NOT NULL,
    quantity        numeric NOT NULL,
    unit            text NOT NULL,
    unit_price      numeric NOT NULL,
    amount_usd      numeric NOT NULL,
    -- 冗余的作废标记,仅供下面的部分唯一索引使用;由 invoices 的触发器维护,
    -- 应用代码不要直接写它。
    invoice_voided  boolean NOT NULL DEFAULT false,
    created_at      timestamptz DEFAULT now(),
    UNIQUE (invoice_id, line_no)
);

CREATE INDEX idx_invoice_lines_invoice ON public.invoice_lines (invoice_id);
CREATE INDEX idx_invoice_lines_sale ON public.invoice_lines (sales_record_id);

-- 硬保证:一张销售最多出现在一张未作废的发票上
CREATE UNIQUE INDEX uq_invoice_lines_live_sale
    ON public.invoice_lines (sales_record_id)
    WHERE NOT invoice_voided;

-- 作废时把标记同步到明细行,释放这些销售以便重开
CREATE OR REPLACE FUNCTION public.propagate_invoice_void()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.status = 'void' AND OLD.status IS DISTINCT FROM 'void' THEN
        UPDATE invoice_lines SET invoice_voided = true WHERE invoice_id = NEW.id;
    END IF;
    RETURN NULL;
END;
$fn$;

CREATE TRIGGER trg_invoices_propagate_void
    AFTER UPDATE ON public.invoices
    FOR EACH ROW EXECUTE FUNCTION public.propagate_invoice_void();

-- 明细行不可变;唯一的例外是上面那个由触发器写的 invoice_voided 标记。
CREATE OR REPLACE FUNCTION public.guard_invoice_line_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    IF NEW.id              IS DISTINCT FROM OLD.id
       OR NEW.invoice_id      IS DISTINCT FROM OLD.invoice_id
       OR NEW.sales_record_id IS DISTINCT FROM OLD.sales_record_id
       OR NEW.line_no         IS DISTINCT FROM OLD.line_no
       OR NEW.description     IS DISTINCT FROM OLD.description
       OR NEW.quantity        IS DISTINCT FROM OLD.quantity
       OR NEW.unit            IS DISTINCT FROM OLD.unit
       OR NEW.unit_price      IS DISTINCT FROM OLD.unit_price
       OR NEW.amount_usd      IS DISTINCT FROM OLD.amount_usd
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_invoice_lines_immutable
    BEFORE UPDATE OR DELETE ON public.invoice_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_invoice_line_mutation();

ALTER TABLE public.invoice_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on invoice_lines"
    ON public.invoice_lines FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on invoice_lines"
    ON public.invoice_lines FOR INSERT TO authenticated WITH CHECK (true);
-- 作废传播需要 UPDATE 权限;列级限制由守卫触发器执行。
CREATE POLICY "authenticated update on invoice_lines"
    ON public.invoice_lines FOR UPDATE TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B4. create_invoice
-- ============================================================================
CREATE FUNCTION public.create_invoice(
    p_customer_id        uuid,
    p_sales_record_ids   uuid[],
    p_issue_date         date DEFAULT NULL,
    p_payment_terms_days integer DEFAULT NULL,
    p_notes              text DEFAULT NULL,
    p_terms_text         text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
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
    v_gst_on      boolean;
    v_gst_rate    numeric;
    v_tax_rate    numeric := 0;
    v_tax         numeric := 0;
    v_existing    text;
    v_lines       jsonb := '[]'::jsonb;  -- 第一趟收集,第二趟落库
    v_line        jsonb;
BEGIN
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

    -- 3. 无缝编号(按 issue_date 的年份),咨询锁串行化;回滚即释放号码
    v_year := EXTRACT(YEAR FROM v_issue)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('invoice_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM invoices
    WHERE code LIKE 'INV-' || v_year::text || '-%';
    v_code := 'INV-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 4. 第一趟:逐张销售校验(存在 → 归属 → 未被占用 → 币种一致)并累计金额。
    --    发票头【等金额算准了再插】—— 头是不可变的(守卫触发器只放行 issued→void),
    --    先插占位再回填就得绕过自己的守卫,那不是正确的做法。
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
               sr.amount_usd, ob.code AS batch_code, ob.unit, m.name AS material_name
        INTO v_sale
        FROM sales_records sr
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        LEFT JOIN materials m ON m.id = ob.material_id
        WHERE sr.id = v_sale_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SALE_NOT_FOUND|%', v_sale_id;
        END IF;

        -- sales_records.customer_id 可空 —— 批次可能在客户还没登记时就卖了。
        -- 因此"无主"的销售允许开给所选客户;只有明确属于【别的】客户时才拒绝。
        IF v_sale.customer_id IS NOT NULL AND v_sale.customer_id <> p_customer_id THEN
            RAISE EXCEPTION 'SALE_WRONG_CUSTOMER|%', v_sale.batch_code;
        END IF;

        -- 已挂在某张在册发票上?给出友好错误(硬保证在部分唯一索引上)
        SELECT i.code INTO v_existing
        FROM invoice_lines il
        JOIN invoices i ON i.id = il.invoice_id
        WHERE il.sales_record_id = v_sale_id AND NOT il.invoice_voided
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'ALREADY_INVOICED|%|%', v_sale.batch_code, v_existing;
        END IF;

        -- 币种必须一致(一张发票只有一个币种)
        IF v_currency IS NULL THEN
            v_currency := v_sale.currency;
        ELSIF v_currency <> v_sale.currency THEN
            RAISE EXCEPTION 'MIXED_CURRENCY|%|%', v_currency, v_sale.currency;
        END IF;

        v_no := v_no + 1;
        v_lines := v_lines || jsonb_build_object(
            'sales_record_id', v_sale_id,
            'line_no', v_no,
            -- 行摘要:产出批次编号 + 物料名(物料可空时只留批次号)
            'description', v_sale.batch_code || COALESCE(' — ' || v_sale.material_name, ''),
            'quantity', v_sale.quantity,
            'unit', v_sale.unit,
            'unit_price', v_sale.unit_price,
            'amount_usd', v_sale.amount_usd);

        v_subtotal := v_subtotal + v_sale.amount_usd;
    END LOOP;

    -- 6. 税:未做 GST 登记时一律 0。【本切不过任何税金分录】——
    --    收入在销售时确认,销项税的正确确认时点同样是销售,不是开票。
    SELECT gst_registered, gst_rate_pct INTO v_gst_on, v_gst_rate
    FROM finance_settings LIMIT 1;
    IF COALESCE(v_gst_on, false) THEN
        v_tax_rate := COALESCE(v_gst_rate, 0);
        v_tax := round(v_subtotal * v_tax_rate / 100.0, 2);
    END IF;

    v_subtotal := round(v_subtotal, 2);

    -- 7. 第二趟:金额已定,一次写对发票头,再落明细行。全程没有对 invoices 的 UPDATE。
    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_usd, tax_rate_pct, tax_usd, total_usd,
                          notes, terms_text, bill_to_snapshot)
    VALUES (v_invoice_id, v_code, p_customer_id, v_issue, v_due, v_terms,
            v_currency, v_subtotal, v_tax_rate, v_tax, round(v_subtotal + v_tax, 2),
            p_notes, p_terms_text,
            -- 抬头快照:取 customers 上确实存在的列(该表没有联系人/邮箱/电话字段)
            jsonb_build_object(
                'code', v_cust.code,
                'legal_name', v_cust.legal_name,
                'short_name', v_cust.short_name,
                'country', v_cust.country,
                'tax_id', v_cust.tax_id,
                'address', v_cust.address,
                'payment_terms', v_cust.payment_terms,
                'incoterm', v_cust.incoterm));

    FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        INSERT INTO invoice_lines (invoice_id, sales_record_id, line_no, description,
                                   quantity, unit, unit_price, amount_usd)
        VALUES (v_invoice_id,
                (v_line->>'sales_record_id')::uuid,
                (v_line->>'line_no')::integer,
                v_line->>'description',
                (v_line->>'quantity')::numeric,
                v_line->>'unit',
                (v_line->>'unit_price')::numeric,
                (v_line->>'amount_usd')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'invoice_id', v_invoice_id,
        'code', v_code,
        'issue_date', v_issue,
        'due_date', v_due,
        'subtotal_usd', v_subtotal,
        'tax_usd', v_tax,
        'total_usd', round(v_subtotal + v_tax, 2),
        'line_count', v_no,
        'currency', v_currency
    );
END;
$function$;

-- ============================================================================
-- B5. void_invoice
-- ============================================================================
CREATE FUNCTION public.void_invoice(p_invoice_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_inv invoices%ROWTYPE;
BEGIN
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

    -- 明细行保留供审计;作废标记由 trg_invoices_propagate_void 同步到明细行,
    -- 这些销售随之重新可开票。
    UPDATE invoices
    SET status = 'void',
        void_reason = btrim(p_reason),
        voided_at = now(),
        voided_by = auth.uid()
    WHERE id = p_invoice_id;

    RETURN jsonb_build_object(
        'invoice_id', p_invoice_id,
        'code', v_inv.code,
        'status', 'void'
    );
END;
$function$;

-- ============================================================================
-- B6. invoice_status —— 每张在册发票一行。已结额从明细行背后的 sales_records
-- 的核销行推导(只计 posted 收款),与 ar_open_items 同口径。
-- ============================================================================
CREATE VIEW public.invoice_status
WITH (security_invoker = on) AS
SELECT i.id AS invoice_id,
       i.code,
       i.customer_id,
       c.legal_name AS customer_name,
       i.issue_date,
       i.due_date,
       i.currency,
       i.total_usd,
       round(COALESCE(s.settled, 0), 2) AS settled_usd,
       round(i.total_usd - COALESCE(s.settled, 0), 2) AS open_usd,
       GREATEST(CURRENT_DATE - i.due_date, 0) AS days_overdue,
       CASE
           WHEN round(i.total_usd - COALESCE(s.settled, 0), 2) <= 0 THEN 'paid'
           WHEN COALESCE(s.settled, 0) > 0 THEN 'partial'
           ELSE 'unpaid'
       END AS payment_state,
       (CURRENT_DATE > i.due_date AND round(i.total_usd - COALESCE(s.settled, 0), 2) > 0) AS overdue
FROM invoices i
JOIN customers c ON c.id = i.customer_id
LEFT JOIN LATERAL (
    SELECT sum(pa.allocated_usd) AS settled
    FROM invoice_lines il
    JOIN payment_allocations pa ON pa.sales_record_id = il.sales_record_id
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE il.invoice_id = i.id
) s ON true
WHERE i.status <> 'void';

-- ============================================================================
-- B7. ar_open_items + invoice_id / invoice_code(列集变了 → DROP + CREATE)
-- 既有列全部保名保义,应收账龄页 / 收付款表单 / AR 单据页照常工作。
-- ============================================================================
DROP VIEW public.ar_open_items;

CREATE VIEW public.ar_open_items
WITH (security_invoker = on) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_usd,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_usd,
    round(sr.amount_usd - COALESCE(s.settled, 0::numeric), 2) AS open_usd,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - sr.sale_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    inv.invoice_id,
    inv.invoice_code
   FROM sales_records sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
     -- 在册发票(未作废)才算数;没开票的销售这两列为 NULL
     LEFT JOIN LATERAL ( SELECT i.id AS invoice_id, i.code AS invoice_code
           FROM invoice_lines il
             JOIN invoices i ON i.id = il.invoice_id
          WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
          LIMIT 1) inv ON true
  WHERE round(sr.amount_usd - COALESCE(s.settled, 0::numeric), 2) > 0::numeric;

COMMIT;
