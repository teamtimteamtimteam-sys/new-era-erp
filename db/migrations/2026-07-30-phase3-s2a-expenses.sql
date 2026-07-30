-- db/migrations/2026-07-30-phase3-s2a-expenses.sql
-- Phase 3 supplement 2a: daily expense entry (DB) + AP unification.
--
-- Expenses are the missing 6xxx entry path. Two posting modes:
--   * 'paid'   → debit expense account / credit bank — settled immediately;
--   * 'unpaid' → debit expense account / credit 2000 AP — becomes an AP document
--                settleable by the existing record_payment.
-- AP documents were previously only priced inbound batches; this cut reworks
-- ap_open_items as a UNION of both document kinds (doc_kind 'inbound'|'expense')
-- and extends record_payment so direction 'out' can allocate to expenses.
--
-- Pieces:
--   B1. account 6110 'CPF – Employer' (outsourced payroll reports salary and
--       employer CPF separately, so they are booked as separate lines).
--   B2. expenses table — immutable, gapless 'EXP-YYYY-NNNN'.
--   B3. payment_allocations + expense_id, XOR widened to 3 via num_nonnulls.
--   B4. finance_attachments + expense_id, XOR widened to 4 (anticipated by its header).
--   B5. record_expense() — validate, gapless code, auto-journal, link.
--   B6. reverse_expense() — reversal JE + mirror row + posted→reversed flip.
--   B7. ap_open_items UNION rework + record_payment expense allocations.

BEGIN;

-- ============================================================================
-- B1. New expense account 6110
-- ============================================================================
INSERT INTO accounts (code, name_en, name_zh, account_type)
VALUES ('6110', 'CPF – Employer', '公积金-雇主部分', 'expense');

-- ============================================================================
-- B2. expenses table
-- ============================================================================
CREATE TABLE public.expenses (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                text NOT NULL UNIQUE,  -- gapless 'EXP-YYYY-NNNN', assigned by record_expense
    expense_date        date NOT NULL,
    account_code        text NOT NULL REFERENCES public.accounts (code),
    amount_ccy          numeric NOT NULL CHECK (amount_ccy > 0),
    currency            text NOT NULL REFERENCES public.currencies (code),
    fx_rate             numeric NOT NULL CHECK (fx_rate > 0),
    amount_usd          numeric NOT NULL,  -- round(amount_ccy × fx_rate, 2)
    payment_status      text NOT NULL CHECK (payment_status IN ('paid','unpaid')),
    bank_account_code   text CHECK (bank_account_code IN ('1000','1010')),
    supplier_id         uuid REFERENCES public.suppliers (id),
    payee_name          text,
    notes               text,
    journal_entry_id    uuid REFERENCES public.journal_entries (id),
    status              text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted','reversed')),
    reversed_by_expense uuid REFERENCES public.expenses (id),
    created_at          timestamptz DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    -- paid → 银行科目必填;unpaid → 必须有供应商(成为 AP 单据)且银行科目为空
    CONSTRAINT expenses_payment_shape CHECK (
        (payment_status = 'paid'   AND bank_account_code IS NOT NULL) OR
        (payment_status = 'unpaid' AND supplier_id IS NOT NULL AND bank_account_code IS NULL)
    )
);

CREATE INDEX idx_expenses_date ON public.expenses (expense_date);
CREATE INDEX idx_expenses_supplier ON public.expenses (supplier_id);
CREATE INDEX idx_expenses_payment_status ON public.expenses (payment_status);

-- 守卫:只放行 posted→reversed 且首挂 reversed_by_expense,其余列逐列锁死
CREATE OR REPLACE FUNCTION public.guard_expense_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NEW.id                  IS DISTINCT FROM OLD.id
       OR NEW.code                IS DISTINCT FROM OLD.code
       OR NEW.expense_date        IS DISTINCT FROM OLD.expense_date
       OR NEW.account_code        IS DISTINCT FROM OLD.account_code
       OR NEW.amount_ccy          IS DISTINCT FROM OLD.amount_ccy
       OR NEW.currency            IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate             IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_usd          IS DISTINCT FROM OLD.amount_usd
       OR NEW.payment_status      IS DISTINCT FROM OLD.payment_status
       OR NEW.bank_account_code   IS DISTINCT FROM OLD.bank_account_code
       OR NEW.supplier_id         IS DISTINCT FROM OLD.supplier_id
       OR NEW.payee_name          IS DISTINCT FROM OLD.payee_name
       OR NEW.notes               IS DISTINCT FROM OLD.notes
       OR NEW.journal_entry_id    IS DISTINCT FROM OLD.journal_entry_id
       OR NEW.created_at          IS DISTINCT FROM OLD.created_at
       OR NEW.created_by          IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
            AND OLD.reversed_by_expense IS NULL AND NEW.reversed_by_expense IS NOT NULL) THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_expenses_immutable
    BEFORE UPDATE OR DELETE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_mutation();

-- RLS:INSERT+SELECT(无 UPDATE 策略 —— 唯一变更入口 reverse_expense,SECURITY DEFINER)
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on expenses"
    ON public.expenses FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on expenses"
    ON public.expenses FOR INSERT TO authenticated WITH CHECK (true);

-- ============================================================================
-- B3. payment_allocations + expense_id (XOR widened to 3)
-- ============================================================================
ALTER TABLE public.payment_allocations
    ADD COLUMN expense_id uuid REFERENCES public.expenses (id);

ALTER TABLE public.payment_allocations
    DROP CONSTRAINT payment_allocations_one_target;
ALTER TABLE public.payment_allocations
    ADD CONSTRAINT payment_allocations_one_target
    CHECK (num_nonnulls(sales_record_id, inbound_batch_id, expense_id) = 1);

CREATE INDEX idx_payment_allocations_expense ON public.payment_allocations (expense_id);

-- ============================================================================
-- B4. finance_attachments + expense_id (XOR widened to 4 — anticipated)
-- ============================================================================
ALTER TABLE public.finance_attachments
    ADD COLUMN expense_id uuid REFERENCES public.expenses (id);

ALTER TABLE public.finance_attachments
    DROP CONSTRAINT finance_attachments_one_parent;
ALTER TABLE public.finance_attachments
    ADD CONSTRAINT finance_attachments_one_parent
    CHECK (num_nonnulls(sales_record_id, inbound_batch_id, payment_id, expense_id) = 1);

CREATE INDEX idx_finance_attachments_expense ON public.finance_attachments (expense_id);

-- ============================================================================
-- journal_entries source_type CHECK: + 'expense'
-- ============================================================================
ALTER TABLE public.journal_entries
    DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries
    ADD CONSTRAINT journal_entries_source_type_check
    CHECK (source_type IN ('manual','purchase','sale','processing_cost','allocation','stocktake','writeoff','payment','fx','expense'));

-- ============================================================================
-- B5. record_expense
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_expense(
    p_expense_date   date,
    p_account_code   text,
    p_amount         numeric,
    p_currency       text DEFAULT 'USD',
    p_fx_rate        numeric DEFAULT NULL,
    p_payment_status text DEFAULT 'paid',
    p_bank_account   text DEFAULT NULL,
    p_supplier_id    uuid DEFAULT NULL,
    p_payee_name     text DEFAULT NULL,
    p_notes          text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_account    record;
    v_fx         numeric;
    v_amount_usd numeric;
    v_bank       text;
    v_expense_id uuid := gen_random_uuid();
    v_year       integer;
    v_seq        integer;
    v_code       text;
    v_je         jsonb;
BEGIN
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
    IF v_account.account_type <> 'expense' THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_EXPENSE|%', v_account.code;
    END IF;

    -- 2. 金额/币种/汇率(同 record_payment 约定:USD 强制 1,非 USD 必须给汇率)
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

    -- 3. 支付状态
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;

    IF p_payment_status = 'paid' THEN
        -- paid:银行科目显式给了必须合法;不给按币种默认(SGD → 1000,USD → 1010)
        IF p_bank_account IS NOT NULL THEN
            IF p_bank_account NOT IN ('1000','1010') THEN
                RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
            END IF;
            v_bank := p_bank_account;
        ELSE
            v_bank := CASE WHEN p_currency = 'SGD' THEN '1000' ELSE '1010' END;
        END IF;
    ELSE
        -- unpaid:必须有在册供应商(它要成为 AP 单据);银行科目必须为空 ——
        -- 传了也直接忽略(挂账时根本没动银行,存下来只会误导)
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
        END IF;
        v_bank := NULL;
    END IF;

    -- 4. USD 金额
    v_amount_usd := round(p_amount * v_fx, 2);

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
    v_je := post_journal_entry(
        p_expense_date,
        'Expense ' || v_code || ' ' || p_account_code,
        'expense', v_expense_id,
        jsonb_build_array(
            jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                               'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
                               'side', 'credit',
                               'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx))
    );

    -- 7. 插入开支单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_usd, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, p_amount, p_currency, v_fx,
            v_amount_usd, p_payment_status, v_bank, p_supplier_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'expense_id', v_expense_id,
        'code', v_code,
        'amount_usd', v_amount_usd,
        'journal_code', v_je->>'code',
        'payment_status', p_payment_status
    );
END;
$function$;

-- ============================================================================
-- B6. reverse_expense
-- ============================================================================
CREATE OR REPLACE FUNCTION public.reverse_expense(p_expense_id uuid, p_memo text DEFAULT NULL)
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
BEGIN
    SELECT * INTO v_orig FROM expenses WHERE id = p_expense_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    v_je := reverse_journal_entry(v_orig.journal_entry_id, CURRENT_DATE, 'Expense reversal ' || v_orig.code);

    -- 镜像开支单(同形状、status 'posted'、挂冲销分录、不带核销行)。
    -- 镜像行只是冲销的记录凭证,不是新的应付单据 —— ap_open_items 里按
    -- "被别的开支单指为 reversed_by_expense" 排除它。
    v_year := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE 'EXP-' || v_year::text || '-%';
    v_mirror_code := 'EXP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_usd, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, CURRENT_DATE, v_orig.account_code,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_usd,
            v_orig.payment_status, v_orig.bank_account_code, v_orig.supplier_id,
            v_orig.payee_name,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());

    UPDATE expenses
    SET status = 'reversed', reversed_by_expense = v_mirror_id
    WHERE id = p_expense_id;

    RETURN jsonb_build_object(
        'reversal_expense_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code'
    );
END;
$function$;

-- ============================================================================
-- B7a. ap_open_items → UNION of inbound batches + unpaid expenses
-- (column set changes → DROP + CREATE, not CREATE OR REPLACE)
-- ============================================================================
DROP VIEW public.ap_open_items;

CREATE VIEW public.ap_open_items
WITH (security_invoker = on) AS
SELECT d.*,
       CURRENT_DATE - d.doc_date AS days_outstanding,
       CASE
           WHEN (CURRENT_DATE - d.doc_date) <= 30 THEN 'b0_30'::text
           WHEN (CURRENT_DATE - d.doc_date) <= 60 THEN 'b31_60'::text
           WHEN (CURRENT_DATE - d.doc_date) <= 90 THEN 'b61_90'::text
           ELSE 'b90_plus'::text
       END AS bucket
FROM (
    -- 进料批次侧:规则不变(已计价、在册、开放余额 > 0);应付额 = 当前 quantity × unit_price
    SELECT 'inbound'::text AS doc_kind,
           ib.id AS doc_id,
           ib.code AS doc_code,
           ib.id AS inbound_batch_id,  -- 保留列,兼容现页面;expense 行为 NULL
           ib.supplier_id,
           sup.legal_name AS supplier_name,
           COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
           round(ib.quantity * ib.unit_price, 2) AS doc_value_usd,
           round(COALESCE(s.settled, 0::numeric), 2) AS settled_usd,
           round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric), 2) AS open_usd
    FROM inbound_batches ib
    JOIN suppliers sup ON sup.id = ib.supplier_id
    LEFT JOIN LATERAL (
        SELECT sum(pa.allocated_usd) AS settled
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
        WHERE pa.inbound_batch_id = ib.id
    ) s ON true
    WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL

    UNION ALL

    -- 开支侧:挂账(unpaid)、posted、开放余额 > 0。
    -- 排除镜像行(被别的开支单指为 reversed_by_expense):它只是冲销的记录凭证,
    -- 不是新的应付单据 —— 否则冲销一笔挂账开支会凭空多出一条敞口。
    SELECT 'expense'::text AS doc_kind,
           e.id AS doc_id,
           e.code AS doc_code,
           NULL::uuid AS inbound_batch_id,
           e.supplier_id,
           sup.legal_name AS supplier_name,
           e.expense_date AS doc_date,
           e.amount_usd AS doc_value_usd,
           round(COALESCE(s.settled, 0::numeric), 2) AS settled_usd,
           round(e.amount_usd - COALESCE(s.settled, 0::numeric), 2) AS open_usd
    FROM expenses e
    JOIN suppliers sup ON sup.id = e.supplier_id
    LEFT JOIN LATERAL (
        SELECT sum(pa.allocated_usd) AS settled
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
        WHERE pa.expense_id = e.id
    ) s ON true
    WHERE e.payment_status = 'unpaid'
      AND e.status = 'posted'
      AND NOT EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = e.id)
) d
WHERE d.open_usd > 0;

-- ============================================================================
-- B7b. record_payment:direction 'out' 的核销目标扩为 inbound_batch_id | expense_id
-- (CREATE OR REPLACE,最小改动:核销循环三选一 + expense 分支 + INSERT 加列)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_payment(p_direction text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_payment_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
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
    v_expense_id   uuid;
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
    --    'in' 只认 sales_record_id;'out' 认 inbound_batch_id 或 expense_id(挂账开支)。
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_sale_id := (v_alloc->>'sales_record_id')::uuid;
        v_batch_id := (v_alloc->>'inbound_batch_id')::uuid;
        v_expense_id := (v_alloc->>'expense_id')::uuid;
        v_alloc_usd := (v_alloc->>'amount_usd')::numeric;

        IF v_alloc_usd IS NULL OR v_alloc_usd <= 0
           OR num_nonnulls(v_sale_id, v_batch_id, v_expense_id) <> 1 THEN
            RAISE EXCEPTION 'ALLOC_INVALID|%', v_alloc::text;
        END IF;

        IF p_direction = 'in' THEN
            IF v_batch_id IS NOT NULL OR v_expense_id IS NOT NULL THEN
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
        ELSIF v_batch_id IS NOT NULL THEN
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
        ELSE
            IF v_sale_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            -- 挂账开支:必须是 unpaid + posted(不存在/已付/已冲销 → ALLOC_INVALID)
            SELECT e.id, e.code AS doc_code, e.supplier_id AS party_id, e.amount_usd AS doc_value
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

            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.expense_id = v_expense_id;
        END IF;

        v_open := round(v_doc_value - v_settled, 2);
        IF v_alloc_usd > v_open THEN
            RAISE EXCEPTION 'ALLOC_EXCEEDS|%|%|%', v_doc.doc_code, v_alloc_usd, v_open;
        END IF;

        INSERT INTO payment_allocations (payment_id, sales_record_id, inbound_batch_id, expense_id, allocated_usd)
        VALUES (v_payment_id, v_sale_id, v_batch_id, v_expense_id, v_alloc_usd);

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

COMMIT;
