-- ============================================================
-- Phase 3 / Cut 1 — finance foundation
-- Date: 2026-07-05
-- Precondition: fresh verified pg_dump backup exists.
--
-- 内容:币种/汇率、会计科目表、不可变且强制平衡的日记账骨架、期间锁,
-- 以及关闭两个估值缺口:销售必须带价(sales_records)、进料补价走审计函数
-- (price_history + 直改拦截)。本 cut 只建骨架:业务事件 → 自动分录在 cut 2 接线。
--
-- 记账口径:分录行以原币录入(amount_ccy + fx_rate),debit/credit 存换算后的
-- USD 金额(= round(amount_ccy × fx_rate, 2));USD 为本位币,fx 恒为 1。
-- ============================================================
BEGIN;

-- ============================================================
-- B1. currencies — 币种参考表(极少变动,无审计列)
-- ============================================================
CREATE TABLE public.currencies (
    code    text PRIMARY KEY CHECK (code IN ('USD','SGD')),  -- 加币种时同步放宽此 CHECK
    name    text NOT NULL,
    is_base boolean NOT NULL DEFAULT false
);

INSERT INTO public.currencies (code, name, is_base) VALUES
    ('USD', 'US Dollar', true),
    ('SGD', 'Singapore Dollar', false);

ALTER TABLE public.currencies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on currencies"
    ON public.currencies AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================
-- B2. fx_rates — 手工汇率表(语义:1 单位外币 = rate_to_usd 美元;USD 无需行)
-- ============================================================
CREATE TABLE public.fx_rates (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    currency    text NOT NULL REFERENCES public.currencies (code),
    rate_to_usd numeric NOT NULL CHECK (rate_to_usd > 0),
    rate_date   date NOT NULL,
    source      text NOT NULL DEFAULT 'manual',
    notes       text,
    deleted_at  timestamptz,
    created_by  uuid DEFAULT auth.uid(),
    updated_by  uuid DEFAULT auth.uid(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (currency, rate_date)
);

CREATE TRIGGER trg_fx_rates_updated_at
    BEFORE UPDATE ON public.fx_rates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.fx_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on fx_rates"
    ON public.fx_rates AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================
-- B3. accounts — 会计科目表
-- 无软删:已过账分录必须永远能解析科目 → 停用(is_active=false)而非删除。
-- ============================================================
CREATE TABLE public.accounts (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code         text NOT NULL UNIQUE,
    name_en      text NOT NULL,
    name_zh      text NOT NULL,
    account_type text NOT NULL CHECK (account_type IN ('asset','liability','equity','revenue','cogs','expense')),
    is_active    boolean NOT NULL DEFAULT true,
    notes        text,
    created_by   uuid DEFAULT auth.uid(),
    updated_by   uuid DEFAULT auth.uid(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_accounts_updated_at
    BEFORE UPDATE ON public.accounts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on accounts"
    ON public.accounts AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

INSERT INTO public.accounts (code, name_en, name_zh, account_type) VALUES
    -- asset
    ('1000', 'Cash at Bank – SGD',            '现金及银行-SGD',   'asset'),
    ('1010', 'Cash at Bank – USD',            '现金及银行-USD',   'asset'),
    ('1100', 'Accounts Receivable',           '应收账款',         'asset'),
    ('1200', 'Inventory – Raw Materials',     '存货-原料',        'asset'),
    ('1210', 'Inventory – Work in Progress',  '存货-在制品',      'asset'),
    ('1220', 'Inventory – Finished Goods',    '存货-成品',        'asset'),
    ('1300', 'Prepayments',                   '预付款项',         'asset'),
    ('1400', 'GST Input Tax',                 'GST 进项税',       'asset'),
    ('1500', 'Fixed Assets – Equipment',      '固定资产-设备',    'asset'),
    ('1510', 'Accumulated Depreciation',      '累计折旧',         'asset'),
    -- liability
    ('2000', 'Accounts Payable',              '应付账款',         'liability'),
    ('2100', 'GST Output Tax',                'GST 销项税',       'liability'),
    ('2200', 'Accrued Expenses',              '应计费用',         'liability'),
    -- equity
    ('3000', 'Share Capital',                 '实收资本',         'equity'),
    ('3100', 'Retained Earnings',             '留存收益',         'equity'),
    -- revenue
    ('4000', 'Sales – Metal Products',        '销售收入-金属产品', 'revenue'),
    ('4100', 'Disposal Service Income',       '处置服务收入',     'revenue'),
    ('4900', 'Other Income',                  '其他收入',         'revenue'),
    -- cogs
    ('5000', 'Material Cost',                 '材料成本',         'cogs'),
    ('5100', 'Processing – Labour',           '加工成本-人工',    'cogs'),
    ('5110', 'Processing – Electricity',      '加工成本-电力',    'cogs'),
    ('5120', 'Processing – Gas',              '加工成本-气体',    'cogs'),
    ('5130', 'Processing – Depreciation',     '加工成本-折旧',    'cogs'),
    ('5140', 'Processing – Consumables',      '加工成本-耗材',    'cogs'),
    ('5150', 'Processing – Waste Treatment',  '加工成本-废物处理', 'cogs'),
    ('5190', 'Processing – Other',            '加工成本-其他',    'cogs'),
    ('5200', 'Inventory Adjustment',          '存货调整损益',     'cogs'),
    -- expense
    ('6000', 'Rent',                          '租金',             'expense'),
    ('6100', 'Salaries & Wages',              '工资薪金',         'expense'),
    ('6200', 'Utilities',                     '水电杂费',         'expense'),
    ('6300', 'Transport & Logistics',         '运输物流费',       'expense'),
    ('6400', 'Professional Fees',             '专业服务费',       'expense'),
    ('6500', 'Bank Charges',                  '银行手续费',       'expense'),
    ('6600', 'FX Gain/Loss',                  '汇兑损益',         'expense'),
    ('6900', 'Miscellaneous',                 '杂项开支',         'expense');

-- ============================================================
-- B4. finance_settings — 单行设置表(期间锁)
-- entry_date < locked_before 的分录一律拒绝(post_journal_entry 检查)。
-- ============================================================
CREATE TABLE public.finance_settings (
    id            boolean PRIMARY KEY DEFAULT true CHECK (id),  -- 单行表:PK 恒为 true
    locked_before date,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid DEFAULT auth.uid()
);

INSERT INTO public.finance_settings (id, locked_before) VALUES (true, NULL);

CREATE TRIGGER trg_finance_settings_updated_at
    BEFORE UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.finance_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on finance_settings"
    ON public.finance_settings AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================
-- B5. journal_entries — 日记账分录头
-- 不可变:无 updated_at/deleted_at,更正一律走冲销分录(reverse_journal_entry)。
-- code 无缝编号:由 post_journal_entry 在事务内取当年 max+1(非序列触发器,
-- 失败回滚会释放号码,保证审计连号)。
-- ============================================================
CREATE TABLE public.journal_entries (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL UNIQUE,
    entry_date  date NOT NULL,
    memo        text,
    source_type text CHECK (source_type IN ('manual','purchase','sale','processing_cost','allocation','stocktake','writeoff','payment','fx')),
    source_id   uuid,
    status      text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted','reversed')),
    reversed_by uuid REFERENCES public.journal_entries (id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid()
);

-- ============================================================
-- B6. journal_lines — 分录行(原币 + 折算 USD 双记录)
-- ============================================================
CREATE TABLE public.journal_lines (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id   uuid NOT NULL REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    account_id uuid NOT NULL REFERENCES public.accounts (id) ON DELETE RESTRICT,
    debit      numeric NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit     numeric NOT NULL DEFAULT 0 CHECK (credit >= 0),
    -- 恰好一边非零(单行不允许两边都记或都不记)
    CONSTRAINT journal_lines_one_side CHECK ((debit = 0) <> (credit = 0)),
    currency   text NOT NULL REFERENCES public.currencies (code),
    amount_ccy numeric NOT NULL CHECK (amount_ccy > 0),  -- 原币金额
    fx_rate    numeric NOT NULL CHECK (fx_rate > 0),     -- 使用的 rate_to_usd;debit/credit = round(amount_ccy × fx_rate, 2)
    line_memo  text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_journal_lines_entry ON public.journal_lines (entry_id);
CREATE INDEX idx_journal_lines_account ON public.journal_lines (account_id);

-- ---- 不可变性 ----
-- RLS 只开 INSERT + SELECT(无 UPDATE/DELETE 策略),外加触发器双保险
-- (同 inventory_movements 的 append-only 配方)。
-- journal_entries 的 UPDATE 仅允许 reverse_journal_entry(SECURITY DEFINER,
-- 绕过 RLS)做 posted → reversed 的精确翻转;逐列比对,其余一律 JOURNAL_IMMUTABLE。

CREATE OR REPLACE FUNCTION public.guard_journal_entry_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'JOURNAL_IMMUTABLE';
    END IF;
    -- 除 status / reversed_by 外任何列变更 → 拒绝
    IF NEW.id          IS DISTINCT FROM OLD.id
       OR NEW.code        IS DISTINCT FROM OLD.code
       OR NEW.entry_date  IS DISTINCT FROM OLD.entry_date
       OR NEW.memo        IS DISTINCT FROM OLD.memo
       OR NEW.source_type IS DISTINCT FROM OLD.source_type
       OR NEW.source_id   IS DISTINCT FROM OLD.source_id
       OR NEW.created_at  IS DISTINCT FROM OLD.created_at
       OR NEW.created_by  IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'JOURNAL_IMMUTABLE';
    END IF;
    -- status/reversed_by 也只认唯一合法迁移:posted → reversed 且首次挂上冲销单
    IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
            AND OLD.reversed_by IS NULL AND NEW.reversed_by IS NOT NULL) THEN
        RAISE EXCEPTION 'JOURNAL_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_journal_entries_immutable
    BEFORE UPDATE OR DELETE ON public.journal_entries
    FOR EACH ROW EXECUTE FUNCTION public.guard_journal_entry_mutation();

CREATE OR REPLACE FUNCTION public.reject_journal_line_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'JOURNAL_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_journal_lines_immutable
    BEFORE UPDATE OR DELETE ON public.journal_lines
    FOR EACH ROW EXECUTE FUNCTION public.reject_journal_line_mutation();

ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on journal_entries"
    ON public.journal_entries FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on journal_entries"
    ON public.journal_entries FOR INSERT TO authenticated WITH CHECK (true);

ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on journal_lines"
    ON public.journal_lines FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on journal_lines"
    ON public.journal_lines FOR INSERT TO authenticated WITH CHECK (true);

-- ============================================================
-- B7. 平衡不变式 — 延迟约束触发器:每张分录 Σdebit = Σcredit 且 ≥ 2 行
-- (行内 XOR 约束保证单行永远不平,所以行数 < 2 必然报不平;
--  仍显式并入同一检查,语义清晰。)
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_journal_balance()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_count  integer;
    v_debit  numeric;
    v_credit numeric;
    v_code   text;
BEGIN
    SELECT count(*), COALESCE(sum(l.debit), 0), COALESCE(sum(l.credit), 0)
    INTO v_count, v_debit, v_credit
    FROM journal_lines l
    WHERE l.entry_id = NEW.entry_id;

    IF v_count < 2 OR v_debit <> v_credit THEN
        SELECT code INTO v_code FROM journal_entries WHERE id = NEW.entry_id;
        RAISE EXCEPTION 'JOURNAL_UNBALANCED|%|%|%', COALESCE(v_code, '?'), v_debit, v_credit;
    END IF;
    RETURN NULL;
END;
$fn$;

CREATE CONSTRAINT TRIGGER trg_journal_lines_balance
    AFTER INSERT ON public.journal_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_journal_balance();

-- ============================================================
-- B8. post_journal_entry — 唯一的过账入口
-- p_lines: [{account_code, side 'debit'|'credit', currency, amount_ccy,
--            fx_rate(非 USD 必填;USD 强制 1), line_memo?}]
-- ============================================================
CREATE OR REPLACE FUNCTION public.post_journal_entry(
    p_entry_date  date,
    p_memo        text,
    p_source_type text,
    p_source_id   uuid,
    p_lines       jsonb
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
AS $function$
DECLARE
    v_locked       date;
    v_line         jsonb;
    v_account      record;
    v_side         text;
    v_currency     text;
    v_amount       numeric;
    v_fx           numeric;
    v_usd          numeric;
    v_total_debit  numeric := 0;
    v_total_credit numeric := 0;
    v_count        integer := 0;
    v_year         integer;
    v_seq          integer;
    v_code         text;
    v_entry_id     uuid;
BEGIN
    IF p_entry_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;

    -- 期间锁:早于 locked_before 的日期拒绝
    SELECT locked_before INTO v_locked FROM finance_settings WHERE id;
    IF v_locked IS NOT NULL AND p_entry_date < v_locked THEN
        RAISE EXCEPTION 'PERIOD_LOCKED|%|%', p_entry_date, v_locked;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|lines';
    END IF;

    -- 无缝编号:咨询锁串行化"取当年最大号+1";失败回滚会释放号码。
    PERFORM pg_advisory_xact_lock(hashtext('je_code')::bigint);
    v_year := EXTRACT(YEAR FROM p_entry_date)::integer;
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM journal_entries
    WHERE code LIKE 'JE-' || v_year::text || '-%';
    v_code := 'JE-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

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

        IF v_currency = 'USD' THEN
            v_fx := 1;  -- 本位币强制 1,忽略传入值
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

        INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate, line_memo)
        VALUES (
            v_entry_id,
            v_account.id,
            CASE WHEN v_side = 'debit'  THEN v_usd ELSE 0 END,
            CASE WHEN v_side = 'credit' THEN v_usd ELSE 0 END,
            v_currency,
            v_amount,
            v_fx,
            v_line->>'line_memo'
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

-- ============================================================
-- B9. reverse_journal_entry — 冲销(唯一允许触碰 status/reversed_by 的路径)
-- SECURITY DEFINER:journal_entries 无 UPDATE 策略(设计使然),
-- 状态翻转只能经由本函数;列级白名单仍由 guard 触发器把关。
-- ============================================================
CREATE OR REPLACE FUNCTION public.reverse_journal_entry(
    p_entry_id      uuid,
    p_reversal_date date,
    p_memo          text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
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
    SELECT jsonb_agg(
        jsonb_build_object(
            'account_code', a.code,
            'side', CASE WHEN l.debit > 0 THEN 'credit' ELSE 'debit' END,
            'currency', l.currency,
            'amount_ccy', l.amount_ccy,
            'fx_rate', l.fx_rate,
            'line_memo', l.line_memo
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

-- ============================================================
-- B10. 销售价格捕获 — sales_records + record_output_sale 换签名
-- ============================================================
-- 销售是事实记录:INSERT+SELECT only + 不可变触发器。
-- 更正走未来的 credit-note(贷项)概念,不改历史行。
CREATE TABLE public.sales_records (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    output_batch_id uuid NOT NULL REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    customer_id     uuid REFERENCES public.customers (id),
    quantity        numeric NOT NULL CHECK (quantity > 0),
    unit_price      numeric NOT NULL CHECK (unit_price > 0),
    currency        text NOT NULL REFERENCES public.currencies (code),
    fx_rate         numeric NOT NULL CHECK (fx_rate > 0),
    amount_usd      numeric NOT NULL,  -- round(quantity × unit_price × fx_rate, 2)
    sale_date       date NOT NULL,
    notes           text,
    movement_id     uuid REFERENCES public.inventory_movements (id),
    created_at      timestamptz DEFAULT now(),
    created_by      uuid DEFAULT auth.uid()
);

CREATE INDEX idx_sales_records_batch ON public.sales_records (output_batch_id);

CREATE OR REPLACE FUNCTION public.reject_sales_record_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'SALE_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_sales_records_immutable
    BEFORE UPDATE OR DELETE ON public.sales_records
    FOR EACH ROW EXECUTE FUNCTION public.reject_sales_record_mutation();

ALTER TABLE public.sales_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on sales_records"
    ON public.sales_records FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on sales_records"
    ON public.sales_records FOR INSERT TO authenticated WITH CHECK (true);

-- 旧签名 (uuid, numeric, date, text) 必须先删,否则 CREATE 出重载,
-- PostgREST 按名字调用会因歧义失败。
DROP FUNCTION IF EXISTS public.record_output_sale(uuid, numeric, date, text);

CREATE OR REPLACE FUNCTION public.record_output_sale(
    p_output_batch_id uuid,
    p_quantity        numeric,
    p_unit_price      numeric,
    p_currency        text,
    p_fx_rate         numeric DEFAULT NULL,
    p_customer_id     uuid DEFAULT NULL,
    p_sale_date       date DEFAULT NULL,
    p_notes           text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_usd    numeric;
    v_movement_id   uuid;
    v_sale_id       uuid;
    v_sale_date     date := COALESCE(p_sale_date, CURRENT_DATE);
BEGIN
    SELECT deleted_at, remaining_qty INTO v_deleted, v_remaining
    FROM output_batches WHERE id = p_output_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QTY_INVALID';
    END IF;
    IF p_quantity > v_remaining THEN
        RAISE EXCEPTION 'SALE_EXCEEDS_REMAINING|%|%', p_quantity, v_remaining;
    END IF;

    -- cut 1 新增:销售必须带价(关闭"收入事件零金额"缺口)
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
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
    v_amount_usd := round(p_quantity * p_unit_price * v_fx, 2);

    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
    VALUES (p_output_batch_id, 'sale', -p_quantity, v_sale_date, p_notes, v_user)
    RETURNING id INTO v_movement_id;

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_usd, sale_date, notes, movement_id, created_by)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_usd, v_sale_date, p_notes, v_movement_id, v_user)
    RETURNING id INTO v_sale_id;

    -- 记账分录本 cut 不生成 —— cut 2 把 sale 事件接进 post_journal_entry。

    v_new_remaining := v_remaining - p_quantity;
    v_state := CASE WHEN v_new_remaining = 0 THEN '已售罄' ELSE '部分售出' END;

    UPDATE output_batches
    SET remaining_qty = v_new_remaining,
        state = v_state,
        updated_by = v_user,
        updated_at = now()
    WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'sold', p_quantity,
        'remaining_qty', v_new_remaining,
        'state', v_state,
        'sale_id', v_sale_id,
        'amount_usd', v_amount_usd
    );
END;
$function$;

-- ============================================================
-- B11. 进料补价(带审计)— price_history + set_inbound_unit_price
-- inbound_batches.unit_price 仍是 USD 口径列;原币与汇率记在 price_history。
-- ============================================================
CREATE TABLE public.price_history (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id uuid NOT NULL REFERENCES public.inbound_batches (id),
    old_unit_price   numeric,           -- 变更前 USD 单价(首次定价为 NULL)
    new_unit_price   numeric NOT NULL,  -- 变更后 USD 单价
    currency         text NOT NULL,
    original_price   numeric NOT NULL,  -- 原币单价(录入值)
    fx_rate          numeric NOT NULL,
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid()
);

CREATE INDEX idx_price_history_batch ON public.price_history (inbound_batch_id);

CREATE OR REPLACE FUNCTION public.reject_price_history_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'PRICE_HISTORY_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_price_history_immutable
    BEFORE UPDATE OR DELETE ON public.price_history
    FOR EACH ROW EXECUTE FUNCTION public.reject_price_history_mutation();

ALTER TABLE public.price_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on price_history"
    ON public.price_history FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on price_history"
    ON public.price_history FOR INSERT TO authenticated WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.set_inbound_unit_price(
    p_inbound_batch_id uuid,
    p_unit_price       numeric,
    p_currency         text DEFAULT 'USD',
    p_fx_rate          numeric DEFAULT NULL,
    p_notes            text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_old     numeric;
    v_deleted timestamptz;
    v_fx      numeric;
    v_usd     numeric;
BEGIN
    SELECT unit_price, deleted_at INTO v_old, v_deleted
    FROM inbound_batches WHERE id = p_inbound_batch_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = 'USD' THEN
        v_fx := 1;
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    v_usd := round(p_unit_price * v_fx, 4);  -- 单价 4 位小数,与 unit_cost_usd 精度一致

    -- GUC 放行本函数内的 unit_price 更新(guard_inbound_price_change),用毕即清,
    -- 免得同事务内后续的直改被误放行(同 movement_ctx 模式)。
    PERFORM set_config('evoltrya.price_ctx', 'set_inbound_unit_price', true);
    UPDATE inbound_batches
    SET unit_price = v_usd, updated_by = v_user, updated_at = now()
    WHERE id = p_inbound_batch_id;
    PERFORM set_config('evoltrya.price_ctx', '', true);

    INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate, notes, created_by)
    VALUES (p_inbound_batch_id, v_old, v_usd, p_currency, p_unit_price, v_fx, p_notes, v_user);

    RETURN jsonb_build_object(
        'batch_id', p_inbound_batch_id,
        'unit_price_usd', v_usd
    );
END;
$function$;

-- 直改拦截:unit_price 只能经 set_inbound_unit_price 变更(INSERT 时带价仍允许 ——
-- 建单定价是正常路径,price_history 只审计建单后的变更)。
CREATE OR REPLACE FUNCTION public.guard_inbound_price_change()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.unit_price IS DISTINCT FROM OLD.unit_price
       AND NULLIF(current_setting('evoltrya.price_ctx', true), '') IS NULL THEN
        RAISE EXCEPTION 'PRICE_VIA_FUNCTION';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_inbound_batches_price_guard
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_price_change();

COMMIT;
