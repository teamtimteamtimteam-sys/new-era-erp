-- db/tables/expenses.sql
-- 日常开支单(6xxx 的唯一入账通道),无缝编号 'EXP-YYYY-NNNN'(record_expense 在
-- 事务内按咨询锁分配,同 JE/收付款手法)。两种入账模式:
--   * 'paid'   → 借 6xxx / 贷银行(1000/1010)—— 即付即结;
--   * 'unpaid' → 借 6xxx / 贷 2000 应付 —— 成为 AP 单据(进 ap_open_items,
--                由 record_payment 的 expense_id 核销行结算)。
-- IMMUTABLE:INSERT+SELECT RLS + 守卫触发器只放行 posted→reversed 且首挂
-- reversed_by_expense(唯一入口 reverse_expense,SECURITY DEFINER —— expenses
-- 无 UPDATE 策略)。分录链接 journal_entry_id 在插入时一次到位(expense id 预生成,
-- 分录先行,无回填 UPDATE)。冲销生成镜像单(status 'posted',notes 'REVERSAL: …',
-- 挂冲销分录,不带核销行)—— 镜像行在 ap_open_items 里被排除(它只是记录凭证)。
--
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s2a-expenses.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

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

ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on expenses"
    ON public.expenses FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on expenses"
    ON public.expenses FOR INSERT TO authenticated WITH CHECK (true);
