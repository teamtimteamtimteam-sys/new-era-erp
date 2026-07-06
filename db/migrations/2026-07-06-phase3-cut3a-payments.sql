-- ============================================================
-- Phase 3 / Cut 3a — payments & AR/AP engine
-- Date: 2026-07-06
-- Precondition: fresh verified pg_dump backup exists.
--
-- 收付款 + 单据级核销,自动入账:
--   * AR 单据 = sales_records(amount_usd 为应收额)
--   * AP 单据 = 已计价的在册进料批次(应付额 = 当前 quantity × unit_price ——
--     改价即改欠款,核销校验永远对着"当前值";未计价批次尚无欠款)
--   * 银行 = 科目 1000(SGD)/ 1010(USD);AR = 1100;AP = 2000
--   * 收款分录:借 银行 / 贷 1100;付款:借 2000 / 贷 银行(原币行 + fx)
--   * 收付款单不可变(INSERT+SELECT RLS + 守卫触发器只放行 posted→reversed 翻转);
--     冲销 = 冲其分录 + 生成镜像收付款单(现金退回记录,不带核销行),
--     开放余额视图排除 status='reversed' 的收付款的核销行
--   * 无缝编号:RCPT-YYYY-NNNN(收)/ PMT-YYYY-NNNN(付),函数内按前缀+年份
--     咨询锁取 max+1(同 JE 码;回滚释放号码)
--   * 期间锁经由分录生效(PERIOD_LOCKED 直接抛出,业务动作一并被拦)
-- 设计说明:payment 的 id 用 gen_random_uuid() 先生成,先过分录(source_id 指向
-- 该 id,source_id 无 FK),再带着 journal_entry_id 一次性插入 payments ——
-- 不可变表无需任何"插入后回填"UPDATE。reverse_payment 是 SECURITY DEFINER
--(payments 无 UPDATE 策略,状态翻转只此一条路;同 reverse_journal_entry 的理由)。
-- ============================================================
BEGIN;

-- ============================================================
-- B1. payments — 收付款单(不可变)
-- ============================================================
CREATE TABLE public.payments (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                text NOT NULL UNIQUE,
    direction           text NOT NULL CHECK (direction IN ('in','out')),
    counterparty_type   text NOT NULL CHECK (counterparty_type IN ('customer','supplier')),
    customer_id         uuid REFERENCES public.customers (id),
    supplier_id         uuid REFERENCES public.suppliers (id),
    CONSTRAINT payments_counterparty_shape CHECK (
        (direction = 'in'  AND counterparty_type = 'customer' AND customer_id IS NOT NULL AND supplier_id IS NULL) OR
        (direction = 'out' AND counterparty_type = 'supplier' AND supplier_id IS NOT NULL AND customer_id IS NULL)
    ),
    amount_ccy          numeric NOT NULL CHECK (amount_ccy > 0),
    currency            text NOT NULL REFERENCES public.currencies (code),
    fx_rate             numeric NOT NULL CHECK (fx_rate > 0),
    amount_usd          numeric NOT NULL,  -- round(amount_ccy × fx_rate, 2)
    bank_account_code   text NOT NULL CHECK (bank_account_code IN ('1000','1010')),
    payment_date        date NOT NULL,
    notes               text,
    journal_entry_id    uuid REFERENCES public.journal_entries (id),
    status              text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted','reversed')),
    reversed_by_payment uuid REFERENCES public.payments (id),
    created_at          timestamptz DEFAULT now(),
    created_by          uuid DEFAULT auth.uid()
);

-- 守卫:只放行 posted→reversed 且首挂 reversed_by_payment,其余列逐列锁死
CREATE OR REPLACE FUNCTION public.guard_payment_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'PAYMENT_IMMUTABLE';
    END IF;
    IF NEW.id                  IS DISTINCT FROM OLD.id
       OR NEW.code                IS DISTINCT FROM OLD.code
       OR NEW.direction           IS DISTINCT FROM OLD.direction
       OR NEW.counterparty_type   IS DISTINCT FROM OLD.counterparty_type
       OR NEW.customer_id         IS DISTINCT FROM OLD.customer_id
       OR NEW.supplier_id         IS DISTINCT FROM OLD.supplier_id
       OR NEW.amount_ccy          IS DISTINCT FROM OLD.amount_ccy
       OR NEW.currency            IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate             IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_usd          IS DISTINCT FROM OLD.amount_usd
       OR NEW.bank_account_code   IS DISTINCT FROM OLD.bank_account_code
       OR NEW.payment_date        IS DISTINCT FROM OLD.payment_date
       OR NEW.notes               IS DISTINCT FROM OLD.notes
       OR NEW.journal_entry_id    IS DISTINCT FROM OLD.journal_entry_id
       OR NEW.created_at          IS DISTINCT FROM OLD.created_at
       OR NEW.created_by          IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'PAYMENT_IMMUTABLE';
    END IF;
    IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
            AND OLD.reversed_by_payment IS NULL AND NEW.reversed_by_payment IS NOT NULL) THEN
        RAISE EXCEPTION 'PAYMENT_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_payments_immutable
    BEFORE UPDATE OR DELETE ON public.payments
    FOR EACH ROW EXECUTE FUNCTION public.guard_payment_mutation();

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on payments"
    ON public.payments FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on payments"
    ON public.payments FOR INSERT TO authenticated WITH CHECK (true);

-- ============================================================
-- B2. payment_allocations — 核销行(不可变;核销目标 XOR)
-- ============================================================
CREATE TABLE public.payment_allocations (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_id       uuid NOT NULL REFERENCES public.payments (id) ON DELETE RESTRICT,
    sales_record_id  uuid REFERENCES public.sales_records (id),
    inbound_batch_id uuid REFERENCES public.inbound_batches (id),
    CONSTRAINT payment_allocations_one_target CHECK ((sales_record_id IS NULL) <> (inbound_batch_id IS NULL)),
    allocated_usd    numeric NOT NULL CHECK (allocated_usd > 0),
    created_at       timestamptz DEFAULT now()
);

CREATE INDEX idx_payment_allocations_payment ON public.payment_allocations (payment_id);
CREATE INDEX idx_payment_allocations_sale ON public.payment_allocations (sales_record_id);
CREATE INDEX idx_payment_allocations_inbound ON public.payment_allocations (inbound_batch_id);

CREATE OR REPLACE FUNCTION public.reject_payment_allocation_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'ALLOCATION_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_payment_allocations_immutable
    BEFORE UPDATE OR DELETE ON public.payment_allocations
    FOR EACH ROW EXECUTE FUNCTION public.reject_payment_allocation_mutation();

ALTER TABLE public.payment_allocations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on payment_allocations"
    ON public.payment_allocations FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on payment_allocations"
    ON public.payment_allocations FOR INSERT TO authenticated WITH CHECK (true);

-- ============================================================
-- B3a. 无缝收付款编号(按前缀+年份各自连号;回滚释放号码)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fin_next_payment_code(p_prefix text, p_date date)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('payment_code_' || p_prefix || '_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM payments
    WHERE code LIKE p_prefix || '-' || v_year::text || '-%';
    RETURN p_prefix || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$fn$;

-- ============================================================
-- B3b. record_payment — 收/付款 + 单据核销 + 自动分录
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_payment(
    p_direction       text,
    p_counterparty_id uuid,
    p_amount          numeric,
    p_currency        text,
    p_fx_rate         numeric DEFAULT NULL,
    p_bank_account    text DEFAULT NULL,
    p_payment_date    date DEFAULT NULL,
    p_notes           text DEFAULT NULL,
    p_allocations     jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
AS $function$
DECLARE
    v_user         uuid := auth.uid();
    v_date         date := COALESCE(p_payment_date, CURRENT_DATE);
    v_fx           numeric;
    v_amount_usd   numeric;
    v_bank         text;
    v_payment_id   uuid := gen_random_uuid();
    v_code         text;
    v_alloc        jsonb;
    v_sale_id      uuid;
    v_batch_id     uuid;
    v_alloc_usd    numeric;
    v_doc          record;
    v_doc_value    numeric;
    v_settled      numeric;
    v_open         numeric;
    v_alloc_total  numeric := 0;
    v_je           jsonb;
BEGIN
    -- 1. 基础校验
    IF p_direction IS NULL OR p_direction NOT IN ('in','out') THEN
        RAISE EXCEPTION 'DIRECTION_INVALID|%', COALESCE(p_direction, '?');
    END IF;

    IF p_direction = 'in' THEN
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM customers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    ELSE
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM suppliers WHERE id = p_counterparty_id AND deleted_at IS NULL
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
    IF p_currency = 'USD' THEN
        v_fx := 1;  -- 本位币强制 1,忽略传入值
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    -- 银行科目:显式给了必须合法;不给按币种默认(SGD → 1000,USD → 1010)
    IF p_bank_account IS NOT NULL THEN
        IF p_bank_account NOT IN ('1000','1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
        END IF;
        v_bank := p_bank_account;
    ELSE
        v_bank := CASE WHEN p_currency = 'SGD' THEN '1000' ELSE '1010' END;
    END IF;

    -- 2. USD 金额
    v_amount_usd := round(p_amount * v_fx, 2);

    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN
        RAISE EXCEPTION 'ALLOC_INVALID|not_an_array';
    END IF;

    -- 3. 先过分录(source_id = 预生成的 payment id,无需回填),期间锁在此生效
    v_code := fin_next_payment_code(CASE WHEN p_direction = 'in' THEN 'RCPT' ELSE 'PMT' END, v_date);
    v_je := post_journal_entry(
        v_date,
        CASE WHEN p_direction = 'in' THEN 'Receipt ' ELSE 'Payment ' END || v_code,
        'payment', v_payment_id,
        CASE WHEN p_direction = 'in' THEN
            jsonb_build_array(
                jsonb_build_object('account_code', v_bank, 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
                jsonb_build_object('account_code', '1100', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx))
        ELSE
            jsonb_build_array(
                jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
                jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx))
        END
    );

    -- 4. 插入收付款单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          amount_ccy, currency, fx_rate, amount_usd, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_payment_id, v_code, p_direction,
            CASE WHEN p_direction = 'in' THEN 'customer' ELSE 'supplier' END,
            CASE WHEN p_direction = 'in' THEN p_counterparty_id END,
            CASE WHEN p_direction = 'out' THEN p_counterparty_id END,
            p_amount, p_currency, v_fx, v_amount_usd, v_bank,
            v_date, p_notes, (v_je->>'entry_id')::uuid, v_user);

    -- 5. 核销行:逐条校验并立即插入(同一目标在一笔里出现两次时,
    --    后一条的累计校验能看到前一条)。顺序:存在 → 归属 → 计价 → 敞口。
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_sale_id := (v_alloc->>'sales_record_id')::uuid;
        v_batch_id := (v_alloc->>'inbound_batch_id')::uuid;
        v_alloc_usd := (v_alloc->>'amount_usd')::numeric;

        IF v_alloc_usd IS NULL OR v_alloc_usd <= 0
           OR ((v_sale_id IS NULL) = (v_batch_id IS NULL)) THEN
            RAISE EXCEPTION 'ALLOC_INVALID|%', v_alloc::text;
        END IF;

        IF p_direction = 'in' THEN
            IF v_batch_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            SELECT sr.id, ob.code AS doc_code, sr.customer_id AS party_id, sr.amount_usd AS doc_value
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

            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.sales_record_id = v_sale_id;
        ELSE
            IF v_sale_id IS NOT NULL THEN
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

            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.inbound_batch_id = v_batch_id;
        END IF;

        v_open := round(v_doc_value - v_settled, 2);
        IF v_alloc_usd > v_open THEN
            RAISE EXCEPTION 'ALLOC_EXCEEDS|%|%|%', v_doc.doc_code, v_alloc_usd, v_open;
        END IF;

        INSERT INTO payment_allocations (payment_id, sales_record_id, inbound_batch_id, allocated_usd)
        VALUES (v_payment_id, v_sale_id, v_batch_id, v_alloc_usd);

        v_alloc_total := v_alloc_total + v_alloc_usd;
    END LOOP;

    -- Σ 核销不得超过款额(欠核销 = 挂账余额,允许)
    IF v_alloc_total > v_amount_usd THEN
        RAISE EXCEPTION 'ALLOC_EXCEEDS_PAYMENT|%|%', v_alloc_total, v_amount_usd;
    END IF;

    RETURN jsonb_build_object(
        'payment_id', v_payment_id,
        'code', v_code,
        'amount_usd', v_amount_usd,
        'journal_code', v_je->>'code',
        'allocated_total', v_alloc_total,
        'unallocated', round(v_amount_usd - v_alloc_total, 2)
    );
END;
$function$;

-- ============================================================
-- B4. reverse_payment — 冲销收付款
-- SECURITY DEFINER:payments 无 UPDATE 策略(设计使然),posted→reversed
-- 翻转只能经由本函数;列级白名单仍由守卫触发器把关(同 reverse_journal_entry)。
-- 镜像单是现金退回记录:同方向、同金额、无核销行;开放余额视图靠
-- "排除 reversed 收付款的核销行"回涨敞口。
-- ============================================================
CREATE OR REPLACE FUNCTION public.reverse_payment(
    p_payment_id uuid,
    p_memo       text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
    v_orig        payments%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_mirror_code text;
    v_je          jsonb;
BEGIN
    SELECT * INTO v_orig FROM payments WHERE id = p_payment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND|%', p_payment_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_payment IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    v_je := reverse_journal_entry(v_orig.journal_entry_id, CURRENT_DATE, 'Payment reversal ' || v_orig.code);

    -- 镜像收付款单(现金退回),挂冲销分录,不带核销行
    v_mirror_code := fin_next_payment_code(CASE WHEN v_orig.direction = 'in' THEN 'RCPT' ELSE 'PMT' END, CURRENT_DATE);
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          amount_ccy, currency, fx_rate, amount_usd, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, v_orig.direction, v_orig.counterparty_type,
            v_orig.customer_id, v_orig.supplier_id,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_usd,
            v_orig.bank_account_code, CURRENT_DATE,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());

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

-- ============================================================
-- B5. AR/AP 开放余额视图(SECURITY INVOKER;排除 reversed 收付款的核销行)
-- ============================================================
CREATE OR REPLACE VIEW public.ar_open_items
WITH (security_invoker = on) AS
SELECT sr.id AS sales_record_id,
       ob.code AS doc_code,
       sr.customer_id,
       c.legal_name AS customer_name,
       sr.sale_date,
       sr.amount_usd,
       round(COALESCE(s.settled, 0), 2) AS settled_usd,
       round(sr.amount_usd - COALESCE(s.settled, 0), 2) AS open_usd,
       (CURRENT_DATE - sr.sale_date) AS days_outstanding,
       CASE WHEN CURRENT_DATE - sr.sale_date <= 30 THEN 'b0_30'
            WHEN CURRENT_DATE - sr.sale_date <= 60 THEN 'b31_60'
            WHEN CURRENT_DATE - sr.sale_date <= 90 THEN 'b61_90'
            ELSE 'b90_plus'
       END AS bucket
FROM sales_records sr
JOIN output_batches ob ON ob.id = sr.output_batch_id
LEFT JOIN customers c ON c.id = sr.customer_id
LEFT JOIN LATERAL (
    SELECT SUM(pa.allocated_usd) AS settled
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.sales_record_id = sr.id
) s ON true
WHERE round(sr.amount_usd - COALESCE(s.settled, 0), 2) > 0;

CREATE OR REPLACE VIEW public.ap_open_items
WITH (security_invoker = on) AS
SELECT ib.id AS inbound_batch_id,
       ib.code AS doc_code,
       ib.supplier_id,
       sup.legal_name AS supplier_name,
       COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
       round(ib.quantity * ib.unit_price, 2) AS amount_usd,
       round(COALESCE(s.settled, 0), 2) AS settled_usd,
       round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0), 2) AS open_usd,
       (CURRENT_DATE - COALESCE(ib.arrival_date, ib.created_at::date)) AS days_outstanding,
       CASE WHEN CURRENT_DATE - COALESCE(ib.arrival_date, ib.created_at::date) <= 30 THEN 'b0_30'
            WHEN CURRENT_DATE - COALESCE(ib.arrival_date, ib.created_at::date) <= 60 THEN 'b31_60'
            WHEN CURRENT_DATE - COALESCE(ib.arrival_date, ib.created_at::date) <= 90 THEN 'b61_90'
            ELSE 'b90_plus'
       END AS bucket
FROM inbound_batches ib
JOIN suppliers sup ON sup.id = ib.supplier_id
LEFT JOIN LATERAL (
    SELECT SUM(pa.allocated_usd) AS settled
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.inbound_batch_id = ib.id
) s ON true
WHERE ib.deleted_at IS NULL
  AND ib.unit_price IS NOT NULL
  AND round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0), 2) > 0;

COMMIT;
