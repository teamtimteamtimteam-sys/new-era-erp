-- db/tables/payment_allocations.sql
-- 收付款核销行:一行核销一张单据(AR = sales_record 或【订单流发票 invoice,SO-3a】,AP = inbound_batch 或
-- expense,预付 = purchase_order,运费 = freight_document —— 六选一 XOR,num_nonnulls = 1)。
--
-- cut 4a 起多了 purchase_order_id:指向采购订单的核销行是【预付款】,不是在还债 ——
-- 付定金那一刻货还不存在,没有任何应付可以核销。所以这类行:
--   * 【没有敞口上限】(不像另外三类要对着单据金额校验),唯一的栏杆是
--     "累计预付 ≤ PO 估算总额 × 1.5",防手滑多打一个零;
--   * 在分录上借的是 1300 预付款项【而不是 2000 应付账款】,record_payment 会把
--     一笔付款里的预付部分与普通应付部分拆成两条借方;
--   * 日后货到并计价了,再由 apply_prepayment() 把它挪到具体批次的应付上
--     (借 2000 / 贷 1300,记在 prepayment_applications)。
-- IMMUTABLE(INSERT+SELECT RLS + 触发器)。开放余额视图(ar/ap_open_items)只计
-- status='posted' 收付款的核销行 —— 冲销收付款后其核销自动失效,敞口回涨。
-- 敞口校验在 record_payment 内:AR 对 sales_records.amount_base,AP 进料对
-- "当前 quantity × unit_price"(改价即改欠款),AP 开支对 expenses.amount_base,
-- 超额 → ALLOC_EXCEEDS。
--
-- NOTE: introduced by db/migrations/2026-07-06-phase3-cut3a-payments.sql;
-- expense_id + widened XOR by db/migrations/2026-07-30-phase3-s2a-expenses.sql;
-- purchase_order_id (prepayments) + widened XOR by
-- db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.payment_allocations (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_id        uuid NOT NULL REFERENCES public.payments (id) ON DELETE RESTRICT,
    sales_record_id   uuid REFERENCES public.sales_records (id),
    inbound_batch_id  uuid REFERENCES public.inbound_batches (id),
    CONSTRAINT payment_allocations_one_target CHECK (num_nonnulls(sales_record_id, inbound_batch_id, expense_id, purchase_order_id, freight_document_id, invoice_id) = 1),
    allocated_base     numeric NOT NULL CHECK (allocated_base > 0),
    created_at        timestamptz DEFAULT now(),
    -- 在列序末尾:s2a / cut 4a 各用 ALTER ADD COLUMN 追加(镜像按线上 attnum 排)
    expense_id        uuid REFERENCES public.expenses (id),
    purchase_order_id uuid REFERENCES public.purchase_orders (id),
    -- ── FIN-2 追加(ALTER 加的列排在末尾)────────────────────────────────────
    -- 核销额以【单据币种】记 —— 敞口与关账在此空间恰好闭合。
    allocated_ccy      numeric NOT NULL CHECK (allocated_ccy > 0),
    -- ── FIN-18 追加 ─────────────────────────────────────────────────────────
    -- 本条核销消耗掉的【付款币种】金额。挂账余额 = payments.amount_ccy − Σ 本列,
    -- 两边同一币种、同一汇率口径。【不要用 allocated_base 反算】—— 那一列按单据
    -- 入账汇率,与款额的结算日汇率之差正是已实现汇兑(7100),反算出来的"挂账"
    -- 是一笔并不存在的余额。
    allocated_pay      numeric NOT NULL,
    CONSTRAINT payment_allocations_allocated_pay_positive CHECK (allocated_pay > 0),
    -- ── FRT-1 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 冲的是一张运费单(对手方是货代)。与其余四个去处同级 —— 五者恰一非空;
    -- 少了它,未付运费永远挂着,因为没有任何一条路能把它结掉。
    freight_document_id uuid REFERENCES public.freight_documents (id),
    -- ── SO-3a 追加(ALTER 加的列排在末尾)──────────────────────────────────
    -- 冲的是一张【订单流】发票(kind='order' —— 它自己就是应收单据,开票即过账)。
    -- 六者恰一非空(XOR 在上面第一列区,重建时以此处文本为准)。
    invoice_id        uuid REFERENCES public.invoices (id)
);

CREATE INDEX idx_payment_allocations_payment ON public.payment_allocations (payment_id);
CREATE INDEX idx_payment_allocations_sale ON public.payment_allocations (sales_record_id);
CREATE INDEX idx_payment_allocations_inbound ON public.payment_allocations (inbound_batch_id);
CREATE INDEX idx_payment_allocations_expense ON public.payment_allocations (expense_id);
CREATE INDEX idx_payment_allocations_po ON public.payment_allocations (purchase_order_id);
CREATE INDEX idx_payment_allocations_invoice ON public.payment_allocations (invoice_id);

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
CREATE POLICY "payment_allocations select by permission"
    ON public.payment_allocations
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "payment_allocations insert by permission"
    ON public.payment_allocations
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.payment_allocations.allocated_base IS
    '本位币核销金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 allocated_usd)。FIN-2 起 = 单据币种核销额 × 单据汇率(解除口径)。';
COMMENT ON COLUMN public.payment_allocations.allocated_ccy IS
    '核销额,以【单据币种】计 —— 敞口与关账在此空间恰好闭合(FIN-2)。';
COMMENT ON COLUMN public.payment_allocations.allocated_pay IS
    '本条核销消耗掉的【付款币种】金额(FIN-18)。= allocated_ccy × rate(单据币种,结算日) / rate(付款币种,结算日);同币种时即 allocated_ccy。挂账余额 = payments.amount_ccy − Σ allocated_pay,两边同为付款币种。不要用 allocated_base 反算 —— 那是单据入账汇率,差额是已实现汇兑。';

COMMENT ON COLUMN public.payment_allocations.invoice_id IS
    'SO-3a:这笔核销冲的是一张【订单流】发票(kind=''order'' —— 它自己就是应收单据,开票即过账)。与其余五个去处同级,六者恰一非空。sale 头的发票不在此列:那种发票的应收在行背后的 sales_records 上,核销照旧走 sales_record_id。';

COMMENT ON COLUMN public.payment_allocations.freight_document_id IS
    'FRT-1:这笔核销冲的是一张运费单(对手方是货代)。与 sales_record_id / inbound_batch_id / expense_id / purchase_order_id 同级 —— 五者恰一非空。';
