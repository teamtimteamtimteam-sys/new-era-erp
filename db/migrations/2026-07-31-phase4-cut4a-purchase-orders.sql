-- db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql
-- Phase 4 cut 4a: purchase orders, per-contract payment schedules, templates,
-- and prepayment accounting (DB only).
--
-- WHY: 采购款是【分期付的】,而定金在货物存在之前就已经离开银行账户 —— 那一刻既没有
-- inbound_batch,也没有任何应付可以核销,record_payment 今天【根本记不下这笔钱】。
-- 会计上的答案是预付款(资产,1300 Prepayments,科目表里已经有),等货到并计价之后
-- 再冲抵应付。
--
-- DESIGN 决策:
--   1. 采购订单【不过任何分录】—— 它是承诺,不是交易。分录只在钱动了(预付)或货到
--      并计价了(既有的 set_inbound_unit_price)时才产生。
--   2. 付款计划【逐合同而定】。期数、比例、触发事件都随交易对手和合同变化 ——
--      任何地方都【不得硬编码】80/10/10 或别的拆法。每张 PO 自带它的计划;模板存在
--      的唯一目的是省去重复录入。本迁移【不预置任何模板】,因为任何预设都是在替
--      Tim 猜他的条款。
--   3. approval_status 两级审批的【结构】先建好,【流程】留到权限切次:列默认
--      'approved',create_purchase_order 立即盖上 approved_at/by。
--
-- Pieces:
--   B1.  purchase_orders
--   B2.  purchase_order_lines
--   B3.  purchase_order_payment_terms
--   B3b. payment_term_templates / payment_term_template_lines / suppliers 默认模板
--   B4.  inbound_batches ← PO 关联
--   B5.  预付款:payment_allocations.purchase_order_id + record_payment 分录拆账
--   B6.  apply_prepayment() + prepayment_applications
--   B7.  ap_open_items 计入预付冲抵
--   B8.  view purchase_order_status
--   B9.  create_purchase_order / cancel_purchase_order / apply_payment_term_template

BEGIN;

-- ============================================================================
-- B1. purchase_orders
-- 承诺台账,不过分录。软删除 + updated_at 触发器(与 pricing_formulas 同款)。
-- ============================================================================
CREATE TABLE public.purchase_orders (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                   text NOT NULL UNIQUE,  -- gapless 'PO-YYYY-NNNN',create_purchase_order 分配
    supplier_id            uuid NOT NULL REFERENCES public.suppliers (id),
    order_date             date NOT NULL,
    expected_delivery_date date,
    currency               text NOT NULL DEFAULT 'USD' REFERENCES public.currencies (code),
    fx_rate                numeric NOT NULL DEFAULT 1 CHECK (fx_rate > 0),
    estimated_total_usd    numeric NOT NULL DEFAULT 0,
    status                 text NOT NULL DEFAULT 'confirmed'
                           CHECK (status IN ('draft','confirmed','receiving','closed','cancelled')),
    -- 【两级审批留到权限切次】:列与取值先定下来,但本切【没有审批流程】——
    -- 默认 'approved',create_purchase_order 直接盖章。结构存在,流程不存在。
    approval_status        text NOT NULL DEFAULT 'approved'
                           CHECK (approval_status IN ('pending','approved','rejected')),
    approved_at            timestamptz,
    approved_by            uuid,
    incoterm               text,
    terms_text             text,
    notes                  text,
    closed_at              timestamptz,
    cancelled_at           timestamptz,
    cancel_reason          text,
    deleted_at             timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid DEFAULT auth.uid()
);

CREATE INDEX idx_purchase_orders_supplier ON public.purchase_orders (supplier_id);
CREATE INDEX idx_purchase_orders_order_date ON public.purchase_orders (order_date);

CREATE TRIGGER trg_purchase_orders_updated_at
    BEFORE UPDATE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on purchase_orders"
    ON public.purchase_orders AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.next_purchase_order_code(p_date date DEFAULT CURRENT_DATE)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('purchase_order_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM purchase_orders
    WHERE code LIKE 'PO-' || v_year::text || '-%';
    RETURN 'PO-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$fn$;

-- ============================================================================
-- B2. purchase_order_lines
-- ============================================================================
CREATE TABLE public.purchase_order_lines (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id    uuid NOT NULL REFERENCES public.purchase_orders (id) ON DELETE CASCADE,
    line_no              integer NOT NULL,
    material_id          uuid NOT NULL REFERENCES public.materials (id),
    quantity             numeric NOT NULL CHECK (quantity > 0),
    unit                 text NOT NULL DEFAULT 'kg',
    pricing_formula_id   uuid REFERENCES public.pricing_formulas (id),
    estimated_unit_price numeric CHECK (estimated_unit_price IS NULL OR estimated_unit_price >= 0),
    estimated_amount_usd numeric NOT NULL DEFAULT 0,
    -- 谈定/预期的金属含量 [{metal, content_pct}]。这是【预期】——
    -- 最终计价以【到货批次的实际化验值】为准(inbound_batch_metals),不以此为准。
    expected_assay       jsonb,
    notes                text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    UNIQUE (purchase_order_id, line_no)
);

CREATE INDEX idx_purchase_order_lines_po ON public.purchase_order_lines (purchase_order_id);

ALTER TABLE public.purchase_order_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on purchase_order_lines"
    ON public.purchase_order_lines AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B3. purchase_order_payment_terms
-- 期数任意、比例或定额任意组合 —— 【计划就是合同写的那样】。
-- 比例是对 PO 估算总额而言;实际化验一落地,计划就只是【指引】而不是债权主张 ——
-- 权威的欠款金额永远是"已计价到货批次的应付"。
-- ============================================================================
CREATE TABLE public.purchase_order_payment_terms (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id uuid NOT NULL REFERENCES public.purchase_orders (id) ON DELETE CASCADE,
    seq               integer NOT NULL,
    label             text NOT NULL,
    percentage        numeric CHECK (percentage IS NULL OR (percentage > 0 AND percentage <= 100)),
    fixed_amount_usd  numeric CHECK (fixed_amount_usd IS NULL OR fixed_amount_usd > 0),
    CONSTRAINT po_payment_terms_pct_xor_fixed CHECK (num_nonnulls(percentage, fixed_amount_usd) = 1),
    trigger_event     text NOT NULL
                      CHECK (trigger_event IN ('on_order','on_shipment','on_arrival','post_assay','fixed_date')),
    due_date          date,
    CONSTRAINT po_payment_terms_fixed_date_needs_due CHECK (
        trigger_event <> 'fixed_date' OR due_date IS NOT NULL
    ),
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (purchase_order_id, seq)
);

CREATE INDEX idx_po_payment_terms_po ON public.purchase_order_payment_terms (purchase_order_id);

ALTER TABLE public.purchase_order_payment_terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on purchase_order_payment_terms"
    ON public.purchase_order_payment_terms AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B3b. 可复用的付款计划模板
-- 只为省去回头客的重复录入。【本迁移不预置任何模板】—— 任何预设都是在猜 Tim 的条款。
-- ============================================================================
CREATE TABLE public.payment_term_templates (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    description text,
    is_active   boolean NOT NULL DEFAULT true,
    deleted_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid()
);

-- 未删除的模板之间名称唯一(删除后可以复用同名)
CREATE UNIQUE INDEX idx_payment_term_templates_name_live
    ON public.payment_term_templates (name) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_payment_term_templates_updated_at
    BEFORE UPDATE ON public.payment_term_templates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.payment_term_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on payment_term_templates"
    ON public.payment_term_templates AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

CREATE TABLE public.payment_term_template_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id      uuid NOT NULL REFERENCES public.payment_term_templates (id) ON DELETE CASCADE,
    seq              integer NOT NULL,
    label            text NOT NULL,
    percentage       numeric CHECK (percentage IS NULL OR (percentage > 0 AND percentage <= 100)),
    fixed_amount_usd numeric CHECK (fixed_amount_usd IS NULL OR fixed_amount_usd > 0),
    CONSTRAINT ptt_lines_pct_xor_fixed CHECK (num_nonnulls(percentage, fixed_amount_usd) = 1),
    trigger_event    text NOT NULL
                     CHECK (trigger_event IN ('on_order','on_shipment','on_arrival','post_assay','fixed_date')),
    -- 模板不可能知道具体日期,所以 'fixed_date' 期在模板里存【相对下单日的天数偏移】,
    -- 由 apply_payment_term_template 换算成 due_date。
    days_offset      integer,
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (template_id, seq)
);

CREATE INDEX idx_ptt_lines_template ON public.payment_term_template_lines (template_id);

ALTER TABLE public.payment_term_template_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on payment_term_template_lines"
    ON public.payment_term_template_lines AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- 供应商默认模板:纯粹的便利,不是约束 —— 任何 PO 都能用任何模板或干脆不用。
ALTER TABLE public.suppliers
    ADD COLUMN default_payment_term_template_id uuid
        REFERENCES public.payment_term_templates (id);

-- ============================================================================
-- B4. inbound_batches ← PO 关联
-- 两列都可空:【没有 PO 的现场收货必须和今天完全一样地继续工作】。
-- ============================================================================
ALTER TABLE public.inbound_batches
    ADD COLUMN purchase_order_id      uuid REFERENCES public.purchase_orders (id),
    ADD COLUMN purchase_order_line_id uuid REFERENCES public.purchase_order_lines (id);

CREATE INDEX idx_inbound_batches_po ON public.inbound_batches (purchase_order_id);

CREATE OR REPLACE FUNCTION public.guard_inbound_po_line_match()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_line_po uuid;
BEGIN
    IF NEW.purchase_order_line_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT purchase_order_id INTO v_line_po
    FROM purchase_order_lines WHERE id = NEW.purchase_order_line_id;
    -- 给了明细行却没给 PO,或明细行不属于所给的 PO —— 两种都是挂错单
    IF v_line_po IS NULL OR NEW.purchase_order_id IS DISTINCT FROM v_line_po THEN
        RAISE EXCEPTION 'PO_LINE_MISMATCH|%', NEW.code;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_inbound_batches_po_line_match
    BEFORE INSERT OR UPDATE OF purchase_order_id, purchase_order_line_id
    ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_po_line_match();

-- ============================================================================
-- B5. 预付款:核销行可以指向 PO
-- ============================================================================
ALTER TABLE public.payment_allocations
    ADD COLUMN purchase_order_id uuid REFERENCES public.purchase_orders (id);

ALTER TABLE public.payment_allocations
    DROP CONSTRAINT payment_allocations_one_target;
ALTER TABLE public.payment_allocations
    ADD CONSTRAINT payment_allocations_one_target CHECK (
        num_nonnulls(sales_record_id, inbound_batch_id, expense_id, purchase_order_id) = 1
    );

CREATE INDEX idx_payment_allocations_po ON public.payment_allocations (purchase_order_id);

-- 分录来源类型增加 'prepayment'(apply_prepayment 用)。
-- 注意:'expense' 是 s2a 那一切加进库里的,但 db/tables/journal_entries.sql 镜像当时
-- 漏了同步 —— 照镜像重建会把既有的 expense 分录判违约。这里以【库里的实际取值】为准,
-- 并在本切一并把镜像补正。
ALTER TABLE public.journal_entries
    DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries
    ADD CONSTRAINT journal_entries_source_type_check CHECK (
        source_type IN ('manual','purchase','sale','processing_cost','allocation',
                        'stocktake','writeoff','payment','fx','expense','prepayment')
    );

-- ============================================================================
-- B6. prepayment_applications:预付冲抵应付的不可变台账
-- ============================================================================
CREATE TABLE public.prepayment_applications (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id uuid NOT NULL REFERENCES public.purchase_orders (id),
    inbound_batch_id  uuid NOT NULL REFERENCES public.inbound_batches (id),
    amount_usd        numeric NOT NULL CHECK (amount_usd > 0),
    notes             text,
    journal_entry_id  uuid REFERENCES public.journal_entries (id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid()
);

CREATE INDEX idx_prepayment_applications_po ON public.prepayment_applications (purchase_order_id);
CREATE INDEX idx_prepayment_applications_inbound ON public.prepayment_applications (inbound_batch_id);

CREATE OR REPLACE FUNCTION public.reject_prepayment_application_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'PREPAYMENT_APPLICATION_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_prepayment_applications_immutable
    BEFORE UPDATE OR DELETE ON public.prepayment_applications
    FOR EACH ROW EXECUTE FUNCTION public.reject_prepayment_application_mutation();

ALTER TABLE public.prepayment_applications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on prepayment_applications"
    ON public.prepayment_applications FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on prepayment_applications"
    ON public.prepayment_applications FOR INSERT TO authenticated WITH CHECK (true);

-- ============================================================================
-- B5(续). record_payment:分录按 1300 / 2000 拆账
--
-- 【为什么必须重排函数结构】原实现在【第 3 步】就把分录过了,而核销行要到【第 5 步】
-- 才逐条解析 —— 分录成型时根本还不知道哪部分是 PO 预付、哪部分是普通应付。所以把
-- 顺序改成:
--     ① 先【只校验】全部核销行(不落库),同时累计 PO 预付额;
--     ② 再取单号、过分录(此时才知道拆账比例);
--     ③ 再插 payments;
--     ④ 最后按①校验通过的结果插 payment_allocations。
-- 原来"同一目标在一笔里出现两次时后一条能看到前一条"的语义,由①里的 v_running
-- 累加器保留(以目标 id 为键的 jsonb),不再依赖"边插边查"。
-- 副作用:期间锁(post_journal_entry 内)现在在核销校验【之后】才触发,因此当两类
-- 错误同时成立时,先报的是核销错误。同一事务内,结果不受影响。
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
    v_po_id        uuid;
    v_alloc_usd    numeric;
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

    -- ========================================================================
    -- ① 核销行:逐条校验,不落库。顺序:存在 → 归属 → 计价 → 敞口。
    --    'in' 只认 sales_record_id;'out' 认 inbound_batch_id / expense_id /
    --    purchase_order_id(预付)。
    -- ========================================================================
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_sale_id    := (v_alloc->>'sales_record_id')::uuid;
        v_batch_id   := (v_alloc->>'inbound_batch_id')::uuid;
        v_expense_id := (v_alloc->>'expense_id')::uuid;
        v_po_id      := (v_alloc->>'purchase_order_id')::uuid;
        v_alloc_usd  := (v_alloc->>'amount_usd')::numeric;

        IF v_alloc_usd IS NULL OR v_alloc_usd <= 0
           OR num_nonnulls(v_sale_id, v_batch_id, v_expense_id, v_po_id) <> 1 THEN
            RAISE EXCEPTION 'ALLOC_INVALID|%', v_alloc::text;
        END IF;

        IF p_direction = 'in' THEN
            IF v_batch_id IS NOT NULL OR v_expense_id IS NOT NULL OR v_po_id IS NOT NULL THEN
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
            v_key := v_sale_id::text;

            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.sales_record_id = v_sale_id;

        ELSIF v_po_id IS NOT NULL THEN
            -- 预付款:PO 上【没有敞口上限】—— 定金不是在还债,那一刻还没有债。
            -- 唯一的栏杆是"累计预付不得超过估算总额 × 1.5",防手滑多打一个零。
            SELECT po.id, po.code AS doc_code, po.supplier_id AS party_id,
                   po.estimated_total_usd, po.status AS po_status
            INTO v_doc
            FROM purchase_orders po
            WHERE po.id = v_po_id AND po.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_po_id;
            END IF;
            IF v_doc.po_status = 'cancelled' THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_doc.doc_code;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_key := v_po_id::text;

            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.purchase_order_id = v_po_id;

            -- 1.5 倍是【刻意留出的余量】:估算按谈价时的行情算,实际化验和金属价格
            -- 波动都会把真实金额顶高,预付超过估算是正常的;超过一半就不正常了。
            v_cap := round(v_doc.estimated_total_usd * 1.5, 2);
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            IF round(v_settled + v_prior + v_alloc_usd, 2) > v_cap THEN
                RAISE EXCEPTION 'PREPAY_EXCEEDS_ESTIMATE|%|%|%',
                    v_doc.doc_code, round(v_settled + v_prior + v_alloc_usd, 2), v_cap;
            END IF;

            v_po_usd := round(v_po_usd + v_alloc_usd, 2);
            v_doc_value := NULL;  -- 无敞口上限,跳过下面的 ALLOC_EXCEEDS

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
            v_key := v_batch_id::text;

            -- 已结 = 收付款核销 + 预付冲抵(B6 起,预付冲抵也在还这张单的应付)
            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.inbound_batch_id = v_batch_id;
            v_settled := v_settled + COALESCE(
                (SELECT SUM(ppa.amount_usd) FROM prepayment_applications ppa
                  WHERE ppa.inbound_batch_id = v_batch_id), 0);

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
            v_key := v_expense_id::text;

            SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.expense_id = v_expense_id;
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

        v_running := v_running || jsonb_build_object(
            v_key, COALESCE((v_running->>v_key)::numeric, 0) + v_alloc_usd);
        v_valid := v_valid || jsonb_build_array(jsonb_build_object(
            'sales_record_id', v_sale_id, 'inbound_batch_id', v_batch_id,
            'expense_id', v_expense_id, 'purchase_order_id', v_po_id,
            'amount_usd', v_alloc_usd));
        v_alloc_total := v_alloc_total + v_alloc_usd;
    END LOOP;

    -- Σ 核销不得超过款额(欠核销 = 挂账余额,允许)
    IF v_alloc_total > v_amount_usd THEN
        RAISE EXCEPTION 'ALLOC_EXCEEDS_PAYMENT|%|%', v_alloc_total, v_amount_usd;
    END IF;

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

    IF p_direction = 'in' THEN
        v_lines := jsonb_build_array(
            jsonb_build_object('account_code', v_bank, 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '1100', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
    ELSIF v_po_usd = 0 THEN
        -- 无预付:与改动前逐字一致
        v_lines := jsonb_build_array(
            jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
    ELSE
        v_ap_usd := round(v_amount_usd - v_po_usd, 2);
        IF v_ap_usd <= 0 THEN
            -- 整笔都是预付:只有一条借方,不能出现 0 元行(post_journal_entry 会拒)
            v_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1300', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
                jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
        ELSE
            v_po_ccy := round(v_po_usd / v_fx, 2);
            v_found := false;
            FOREACH v_delta IN ARRAY ARRAY[0, 0.01, -0.01, 0.02, -0.02]::numeric[]
            LOOP
                IF v_po_ccy + v_delta > 0 AND p_amount - (v_po_ccy + v_delta) > 0
                   AND round((v_po_ccy + v_delta) * v_fx, 2)
                       + round((p_amount - v_po_ccy - v_delta) * v_fx, 2) = v_amount_usd THEN
                    v_po_ccy := v_po_ccy + v_delta;
                    v_found := true;
                    EXIT;
                END IF;
            END LOOP;
            IF NOT v_found THEN
                RAISE EXCEPTION 'PREPAY_SPLIT_UNBALANCED|%|%|%', v_amount_usd, v_po_usd, v_fx;
            END IF;
            v_ap_ccy := p_amount - v_po_ccy;
            v_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1300', 'side', 'debit',  'currency', p_currency, 'amount_ccy', v_po_ccy, 'fx_rate', v_fx, 'line_memo', 'Prepayment'),
                jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', p_currency, 'amount_ccy', v_ap_ccy, 'fx_rate', v_fx),
                jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx));
        END IF;
    END IF;

    v_je := post_journal_entry(
        v_date,
        CASE WHEN p_direction = 'in' THEN 'Receipt ' ELSE 'Payment ' END || v_code,
        'payment', v_payment_id, v_lines);

    -- ③ 插入收付款单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          amount_ccy, currency, fx_rate, amount_usd, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_payment_id, v_code, p_direction,
            CASE WHEN p_direction = 'in' THEN 'customer' ELSE 'supplier' END,
            CASE WHEN p_direction = 'in' THEN p_counterparty_id END,
            CASE WHEN p_direction = 'out' THEN p_counterparty_id END,
            p_amount, p_currency, v_fx, v_amount_usd, v_bank,
            v_date, p_notes, (v_je->>'entry_id')::uuid, v_user);

    -- ④ 核销行落库(①已全部校验过,这里只写)
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(v_valid)
    LOOP
        INSERT INTO payment_allocations (payment_id, sales_record_id, inbound_batch_id,
                                         expense_id, purchase_order_id, allocated_usd)
        VALUES (v_payment_id,
                (v_alloc->>'sales_record_id')::uuid,
                (v_alloc->>'inbound_batch_id')::uuid,
                (v_alloc->>'expense_id')::uuid,
                (v_alloc->>'purchase_order_id')::uuid,
                (v_alloc->>'amount_usd')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'payment_id', v_payment_id,
        'code', v_code,
        'amount_usd', v_amount_usd,
        'journal_code', v_je->>'code',
        'allocated_total', v_alloc_total,
        'unallocated', round(v_amount_usd - v_alloc_total, 2),
        'prepaid_total', v_po_usd
    );
END;
$function$;

-- ============================================================================
-- B6(续). apply_prepayment:把预付的钱挪到一张【已收货、已计价】的批次上
--   借 2000 应付账款 / 贷 1300 预付款项
-- ============================================================================
CREATE OR REPLACE FUNCTION public.apply_prepayment(p_purchase_order_id uuid, p_inbound_batch_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_po        record;
    v_batch     record;
    v_prepaid   numeric;
    v_applied   numeric;
    v_available numeric;
    v_value     numeric;
    v_settled   numeric;
    v_open      numeric;
    v_app_id    uuid := gen_random_uuid();
    v_je        jsonb;
BEGIN
    SELECT po.id, po.code, po.supplier_id, po.status
    INTO v_po
    FROM purchase_orders po
    WHERE po.id = p_purchase_order_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT ib.id, ib.code, ib.supplier_id, ib.quantity, ib.unit_price
    INTO v_batch
    FROM inbound_batches ib
    WHERE ib.id = p_inbound_batch_id AND ib.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF v_batch.unit_price IS NULL THEN
        RAISE EXCEPTION 'INBOUND_UNPRICED|%', v_batch.code;
    END IF;
    IF v_batch.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
        RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_batch.code;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    -- 可用预付 = 已付到该 PO 的预付(仅 posted 收付款) − 已冲抵的部分
    SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_prepaid
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;

    SELECT COALESCE(SUM(ppa.amount_usd), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;

    v_available := round(v_prepaid - v_applied, 2);
    IF p_amount > v_available THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', v_available, p_amount;
    END IF;

    -- 批次敞口 = 当前批次价值 − 收付款核销 − 已冲抵的预付
    v_value := round(v_batch.quantity * v_batch.unit_price, 2);
    SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.inbound_batch_id = p_inbound_batch_id;
    v_settled := v_settled + COALESCE(
        (SELECT SUM(ppa.amount_usd) FROM prepayment_applications ppa
          WHERE ppa.inbound_batch_id = p_inbound_batch_id), 0);
    v_open := round(v_value - v_settled, 2);
    IF p_amount > v_open THEN
        RAISE EXCEPTION 'EXCEEDS_OPEN|%|%', v_open, p_amount;
    END IF;

    -- 分录:预付转为对该批次应付的清偿(钱早就出去了,这里只是科目之间的搬运)
    v_je := post_journal_entry(
        CURRENT_DATE,
        'Prepayment applied ' || v_po.code || ' → ' || v_batch.code,
        'prepayment', v_app_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', 'USD', 'amount_ccy', p_amount, 'fx_rate', 1),
            jsonb_build_object('account_code', '1300', 'side', 'credit', 'currency', 'USD', 'amount_ccy', p_amount, 'fx_rate', 1)));

    INSERT INTO prepayment_applications (id, purchase_order_id, inbound_batch_id, amount_usd,
                                         notes, journal_entry_id, created_by)
    VALUES (v_app_id, p_purchase_order_id, p_inbound_batch_id, p_amount,
            p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'application_id', v_app_id,
        'purchase_order_id', p_purchase_order_id,
        'inbound_batch_id', p_inbound_batch_id,
        'amount_usd', p_amount,
        'journal_code', v_je->>'code',
        'prepaid_remaining', round(v_available - p_amount, 2)
    );
END;
$function$;

-- ============================================================================
-- B7. ap_open_items:进料侧的已结额【必须计入预付冲抵】,
--     否则一张被定金付清的批次会永远显示未付。
--     列集未变 → CREATE OR REPLACE(不必 DROP,下游页面无感)。
-- ============================================================================
CREATE OR REPLACE VIEW public.ap_open_items
WITH (security_invoker = on) AS
 SELECT doc_kind,
    doc_id,
    doc_code,
    inbound_batch_id,
    supplier_id,
    supplier_name,
    doc_date,
    doc_value_usd,
    settled_usd,
    open_usd,
    CURRENT_DATE - doc_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - doc_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - doc_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - doc_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket
   FROM ( SELECT 'inbound'::text AS doc_kind,
            ib.id AS doc_id,
            ib.code AS doc_code,
            ib.id AS inbound_batch_id,
            ib.supplier_id,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
            round(ib.quantity * ib.unit_price, 2) AS doc_value_usd,
            round(COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric), 2) AS settled_usd,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_usd
           FROM inbound_batches ib
             JOIN suppliers sup ON sup.id = ib.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.inbound_batch_id = ib.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_usd) AS applied
                   FROM prepayment_applications ppa
                  WHERE ppa.inbound_batch_id = ib.id) pp ON true
          WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
        UNION ALL
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
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.expense_id = e.id) s ON true
          WHERE e.payment_status = 'unpaid'::text AND e.status = 'posted'::text AND NOT (EXISTS ( SELECT 1
                   FROM expenses o
                  WHERE o.reversed_by_expense = e.id))) d
  WHERE open_usd > 0::numeric;

-- ============================================================================
-- B8. view purchase_order_status
-- ============================================================================
CREATE OR REPLACE VIEW public.purchase_order_status
WITH (security_invoker = on) AS
 SELECT po.id AS po_id,
    po.code,
    po.supplier_id,
    sup.legal_name AS supplier_name,
    po.order_date,
    po.expected_delivery_date,
    po.status,
    po.currency,
    po.estimated_total_usd,
    round(COALESCE(pre.prepaid, 0::numeric), 2) AS prepaid_usd,
    round(COALESCE(app.applied, 0::numeric), 2) AS prepaid_applied_usd,
    round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app.applied, 0::numeric), 2) AS prepaid_remaining_usd,
    COALESCE(rec.batches, 0::bigint) AS received_batches,
    round(COALESCE(rec.qty, 0::numeric), 4) AS received_qty,
    round(COALESCE(ord.qty, 0::numeric), 4) AS ordered_qty,
    CASE WHEN COALESCE(ord.qty, 0::numeric) = 0::numeric THEN NULL::numeric
         ELSE round(COALESCE(rec.qty, 0::numeric) / ord.qty * 100::numeric, 2)
    END AS receipt_pct
   FROM purchase_orders po
     JOIN suppliers sup ON sup.id = po.supplier_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS prepaid
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.purchase_order_id = po.id) pre ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_usd) AS applied
           FROM prepayment_applications ppa
          WHERE ppa.purchase_order_id = po.id) app ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS batches, sum(ib.quantity) AS qty
           FROM inbound_batches ib
          WHERE ib.purchase_order_id = po.id AND ib.deleted_at IS NULL) rec ON true
     LEFT JOIN LATERAL ( SELECT sum(pol.quantity) AS qty
           FROM purchase_order_lines pol
          WHERE pol.purchase_order_id = po.id) ord ON true
  WHERE po.deleted_at IS NULL AND po.status <> 'cancelled'::text;

-- ============================================================================
-- B9. create_purchase_order / cancel_purchase_order / apply_payment_term_template
-- ============================================================================
CREATE OR REPLACE FUNCTION public.create_purchase_order(p_supplier_id uuid, p_order_date date, p_expected_delivery date, p_currency text, p_fx_rate numeric, p_incoterm text, p_terms_text text, p_notes text, p_lines jsonb, p_payment_terms jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_date       date := COALESCE(p_order_date, CURRENT_DATE);
    v_fx         numeric;
    v_po_id      uuid := gen_random_uuid();
    v_code       text;
    v_line       jsonb;
    v_line_no    integer;
    v_qty        numeric;
    v_price      numeric;
    v_amount     numeric;
    v_material   uuid;
    v_formula    uuid;
    v_f          record;
    v_total      numeric := 0;
    v_count      integer := 0;
    v_term       jsonb;
    v_seq        integer;
    v_expect     integer := 0;
    v_pct_total  numeric := 0;
    v_term_count integer := 0;
BEGIN
    IF p_supplier_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
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

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_code := next_purchase_order_code(v_date);

    INSERT INTO purchase_orders (id, code, supplier_id, order_date, expected_delivery_date,
                                 currency, fx_rate, estimated_total_usd, status,
                                 approval_status, approved_at, approved_by,
                                 incoterm, terms_text, notes, created_by, updated_by)
    VALUES (v_po_id, v_code, p_supplier_id, v_date, p_expected_delivery,
            p_currency, v_fx, 0, 'confirmed',
            -- 两级审批留到权限切次:这里直接盖章,结构在、流程不在(见 B1 注释)
            'approved', now(), v_user,
            p_incoterm, p_terms_text, p_notes, v_user, v_user);

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;
        v_line_no := COALESCE((v_line->>'line_no')::integer, v_count);
        v_material := (v_line->>'material_id')::uuid;
        v_qty := (v_line->>'quantity')::numeric;
        v_price := (v_line->>'estimated_unit_price')::numeric;
        v_formula := (v_line->>'pricing_formula_id')::uuid;

        IF v_material IS NULL OR NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_material AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', COALESCE(v_material::text, '?');
        END IF;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_INVALID|%', v_line_no;
        END IF;
        IF v_formula IS NOT NULL THEN
            SELECT id, code, is_active, deleted_at INTO v_f
            FROM pricing_formulas WHERE id = v_formula;
            IF NOT FOUND OR v_f.deleted_at IS NOT NULL THEN
                RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', v_formula;
            END IF;
            IF NOT v_f.is_active THEN
                RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
            END IF;
        END IF;

        -- 没给估价就是 0:PO 是承诺,估算金额可以留白(公式定价的料常常如此)
        v_amount := CASE WHEN v_price IS NULL THEN 0 ELSE round(v_qty * v_price, 2) END;
        v_total := v_total + v_amount;

        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity,
                                          unit, pricing_formula_id, estimated_unit_price,
                                          estimated_amount_usd, expected_assay, notes, created_by)
        VALUES (v_po_id, v_line_no, v_material, v_qty,
                COALESCE(v_line->>'unit', 'kg'), v_formula, v_price,
                v_amount, v_line->'expected_assay', v_line->>'notes', v_user);
    END LOOP;

    UPDATE purchase_orders SET estimated_total_usd = v_total, updated_by = v_user
    WHERE id = v_po_id;

    -- 付款计划是【可选的】:有些采购就是到货即付,没有分期可言。
    IF p_payment_terms IS NOT NULL AND jsonb_typeof(p_payment_terms) = 'array'
       AND jsonb_array_length(p_payment_terms) > 0 THEN
        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            v_expect := v_expect + 1;
            v_seq := (v_term->>'seq')::integer;
            IF v_seq IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'TERMS_SEQ_INVALID';
            END IF;
            v_pct_total := v_pct_total + COALESCE((v_term->>'percentage')::numeric, 0);

            INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                                      fixed_amount_usd, trigger_event, due_date, notes)
            VALUES (v_po_id, v_seq, v_term->>'label',
                    (v_term->>'percentage')::numeric,
                    (v_term->>'fixed_amount_usd')::numeric,
                    v_term->>'trigger_event',
                    (v_term->>'due_date')::date,
                    v_term->>'notes');
            v_term_count := v_term_count + 1;
        END LOOP;

        IF v_pct_total > 100 THEN
            RAISE EXCEPTION 'TERMS_PCT_EXCEEDS|%', v_pct_total;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'purchase_order_id', v_po_id,
        'code', v_code,
        'estimated_total_usd', v_total,
        'line_count', v_count,
        'term_count', v_term_count
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_purchase_order(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_po      record;
    v_batches integer;
    v_applied numeric;
BEGIN
    SELECT id, code, status INTO v_po
    FROM purchase_orders WHERE id = p_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT count(*) INTO v_batches
    FROM inbound_batches WHERE purchase_order_id = p_id AND deleted_at IS NULL;
    IF v_batches > 0 THEN
        RAISE EXCEPTION 'PO_HAS_RECEIPTS|%', v_batches;
    END IF;

    SELECT COALESCE(SUM(amount_usd), 0) INTO v_applied
    FROM prepayment_applications WHERE purchase_order_id = p_id;
    IF v_applied > 0 THEN
        RAISE EXCEPTION 'PO_HAS_APPLIED_PREPAYMENTS|%', v_applied;
    END IF;

    UPDATE purchase_orders
    SET status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason, updated_by = v_user
    WHERE id = p_id;

    RETURN jsonb_build_object('purchase_order_id', p_id, 'code', v_po.code, 'status', 'cancelled');
END;
$function$;

CREATE OR REPLACE FUNCTION public.apply_payment_term_template(p_purchase_order_id uuid, p_template_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_po    record;
    v_tpl   record;
    v_count integer := 0;
BEGIN
    SELECT id, code, order_date, status INTO v_po
    FROM purchase_orders WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT id, name INTO v_tpl
    FROM payment_term_templates
    WHERE id = p_template_id AND deleted_at IS NULL AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEMPLATE_NOT_FOUND|%', COALESCE(p_template_id::text, '?');
    END IF;

    -- 【替换】而不是追加:套模板的语义是"这张 PO 的计划就是模板说的那样"
    DELETE FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                              fixed_amount_usd, trigger_event, due_date, notes)
    SELECT p_purchase_order_id, l.seq, l.label, l.percentage, l.fixed_amount_usd, l.trigger_event,
           -- 模板存的是相对下单日的天数偏移(模板不可能知道具体日期)
           CASE WHEN l.trigger_event = 'fixed_date'
                THEN v_po.order_date + COALESCE(l.days_offset, 0)
                ELSE NULL END,
           l.notes
    FROM payment_term_template_lines l
    WHERE l.template_id = p_template_id
    ORDER BY l.seq;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN jsonb_build_object('purchase_order_id', p_purchase_order_id, 'term_count', v_count);
END;
$function$;

COMMIT;
