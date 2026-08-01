-- db/tables/payments.sql
-- 收付款单(收款 RCPT-YYYY-NNNN / 付款 PMT-YYYY-NNNN,无缝编号由
-- fin_next_payment_code 在 record_payment 事务内分配,非序列触发器)。
-- IMMUTABLE:INSERT+SELECT RLS + 守卫触发器只放行 posted→reversed 且首挂
-- reversed_by_payment(唯一入口 reverse_payment,SECURITY DEFINER —— payments
-- 无 UPDATE 策略)。分录链接 journal_entry_id 在插入时一次到位(payment id 预生成,
-- 分录先行,无回填 UPDATE)。冲销生成同方向镜像单(现金退回记录,不带核销行)。
--
-- NOTE: introduced by db/migrations/2026-07-06-phase3-cut3a-payments.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

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
CREATE POLICY "payments select by permission"
    ON public.payments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "payments insert by permission"
    ON public.payments
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));
