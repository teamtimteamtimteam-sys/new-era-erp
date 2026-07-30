-- db/tables/payment_allocations.sql
-- 收付款核销行:一行核销一张单据(AR = sales_record,AP = inbound_batch 或
-- expense,三选一 XOR,num_nonnulls = 1)。
-- IMMUTABLE(INSERT+SELECT RLS + 触发器)。开放余额视图(ar/ap_open_items)只计
-- status='posted' 收付款的核销行 —— 冲销收付款后其核销自动失效,敞口回涨。
-- 敞口校验在 record_payment 内:AR 对 sales_records.amount_usd,AP 进料对
-- "当前 quantity × unit_price"(改价即改欠款),AP 开支对 expenses.amount_usd,
-- 超额 → ALLOC_EXCEEDS。
--
-- NOTE: introduced by db/migrations/2026-07-06-phase3-cut3a-payments.sql;
-- expense_id + widened XOR by db/migrations/2026-07-30-phase3-s2a-expenses.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.payment_allocations (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_id       uuid NOT NULL REFERENCES public.payments (id) ON DELETE RESTRICT,
    sales_record_id  uuid REFERENCES public.sales_records (id),
    inbound_batch_id uuid REFERENCES public.inbound_batches (id),
    expense_id       uuid REFERENCES public.expenses (id),
    CONSTRAINT payment_allocations_one_target CHECK (num_nonnulls(sales_record_id, inbound_batch_id, expense_id) = 1),
    allocated_usd    numeric NOT NULL CHECK (allocated_usd > 0),
    created_at       timestamptz DEFAULT now()
);

CREATE INDEX idx_payment_allocations_payment ON public.payment_allocations (payment_id);
CREATE INDEX idx_payment_allocations_sale ON public.payment_allocations (sales_record_id);
CREATE INDEX idx_payment_allocations_inbound ON public.payment_allocations (inbound_batch_id);
CREATE INDEX idx_payment_allocations_expense ON public.payment_allocations (expense_id);

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
