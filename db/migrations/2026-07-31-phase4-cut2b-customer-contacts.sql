-- db/migrations/2026-07-31-phase4-cut2b-customer-contacts.sql
-- Phase 4 cut 2b(附带):customers 增加联系方式三列 —— 开票要用。
--
-- cut 2a 的 B0 勘察发现 customers 上【没有任何联系人/邮箱/电话字段】,
-- 于是发票的 bill_to_snapshot 只能存 code/legal_name/short_name/country/
-- tax_id/address/payment_terms/incoterm。这里补上,今后开出的发票抬头就能带上
-- 联系人与邮箱(快照按开票当刻取值,老发票不受影响)。
--
-- 三列都可空、都不加 CHECK:邮箱与电话的国际写法差异太大(+65 / 0086- / 分机 /
-- 多个邮箱并列……),在库里做格式校验只会误伤真实数据。要校验就放到录入端做提示,
-- 而不是让数据库拒收。
--
-- NOTE: customers 建表脚本没有 db/tables 镜像 —— 早期主数据表(customers/
-- suppliers/materials/inbound_batches/output_batches)先于镜像约定存在,
-- 目录里只有它们的附件子表镜像。此处不补一份残缺的镜像,仅在此说明。

BEGIN;

ALTER TABLE public.customers
    ADD COLUMN email text,
    ADD COLUMN phone text,
    ADD COLUMN contact_person text;

-- create_invoice 的抬头快照要把这三列一起存下来 —— 否则字段建了却永远到不了发票上。
-- 只改 bill_to_snapshot 的构造,其余逻辑与 cut 2a 完全一致。
-- 老发票的快照里没有这三个键,详情页按"有才显示"渲染,不受影响。
CREATE OR REPLACE FUNCTION public.create_invoice(
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
        IF v_sale.customer_id IS NOT NULL AND v_sale.customer_id <> p_customer_id THEN
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

        v_no := v_no + 1;
        v_lines := v_lines || jsonb_build_object(
            'sales_record_id', v_sale_id,
            'line_no', v_no,
            'description', v_sale.batch_code || COALESCE(' — ' || v_sale.material_name, ''),
            'quantity', v_sale.quantity,
            'unit', v_sale.unit,
            'unit_price', v_sale.unit_price,
            'amount_usd', v_sale.amount_usd);

        v_subtotal := v_subtotal + v_sale.amount_usd;
    END LOOP;

    -- 5. 税:未做 GST 登记时一律 0。【不过任何税金分录】—— 正确确认时点是销售,不是开票。
    SELECT gst_registered, gst_rate_pct INTO v_gst_on, v_gst_rate
    FROM finance_settings LIMIT 1;
    IF COALESCE(v_gst_on, false) THEN
        v_tax_rate := COALESCE(v_gst_rate, 0);
        v_tax := round(v_subtotal * v_tax_rate / 100.0, 2);
    END IF;

    v_subtotal := round(v_subtotal, 2);

    -- 6. 第二趟:金额已定,一次写对发票头,再落明细行。
    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_usd, tax_rate_pct, tax_usd, total_usd,
                          notes, terms_text, bill_to_snapshot)
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
                -- cut 2b 新增
                'contact_person', v_cust.contact_person,
                'email', v_cust.email,
                'phone', v_cust.phone));

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

COMMIT;
