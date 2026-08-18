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
    counterparty_type   text NOT NULL CHECK (counterparty_type IN ('customer','supplier','employee')),
    customer_id         uuid REFERENCES public.customers (id),
    supplier_id         uuid REFERENCES public.suppliers (id),
    -- PAYEE-1a:出款有两种往来对象,收款仍只有一种。
    -- 三支各自把另外两列钉成 NULL —— "恰好一个"在这里是逐支写死的,
    -- 而不是一句 num_nonnulls:方向与种类必须同时对上,否则
    -- direction='in' 配 counterparty_type='employee' 会溜过去。
    CONSTRAINT payments_counterparty_shape_v2 CHECK (
        (direction = 'in'  AND counterparty_type = 'customer' AND customer_id IS NOT NULL AND supplier_id IS NULL AND employee_id IS NULL) OR
        (direction = 'out' AND counterparty_type = 'supplier' AND supplier_id IS NOT NULL AND customer_id IS NULL AND employee_id IS NULL) OR
        (direction = 'out' AND counterparty_type = 'employee' AND employee_id IS NOT NULL AND customer_id IS NULL AND supplier_id IS NULL)
    ),
    amount_ccy          numeric NOT NULL CHECK (amount_ccy > 0),
    currency            text NOT NULL REFERENCES public.currencies (code),
    fx_rate             numeric NOT NULL CHECK (fx_rate > 0),
    amount_base          numeric NOT NULL,  -- round(amount_ccy × fx_rate, 2)
    bank_account_code   text NOT NULL CHECK (bank_account_code IN ('1000','1010')),
    payment_date        date NOT NULL,
    notes               text,
    journal_entry_id    uuid REFERENCES public.journal_entries (id),
    status              text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted','reversed')),
    reversed_by_payment uuid REFERENCES public.payments (id),
    created_at          timestamptz DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    -- ── PAYEE-1a 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 出款也可以付给【员工】(报销);收款方向必须为空。
    employee_id         uuid REFERENCES public.employees (id)
);

-- 守卫:只放行 posted→reversed 且首挂 reversed_by_payment,其余列逐列锁死
CREATE OR REPLACE FUNCTION public.guard_payment_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
       -- PAYEE-1a fu1:同上 —— 让清单完整;兜底本已拒掉非冲销的 UPDATE。
       OR NEW.employee_id         IS DISTINCT FROM OLD.employee_id
       OR NEW.amount_ccy          IS DISTINCT FROM OLD.amount_ccy
       OR NEW.currency            IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate             IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_base          IS DISTINCT FROM OLD.amount_base
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
$function$;

CREATE TRIGGER trg_payments_immutable
    BEFORE UPDATE OR DELETE ON public.payments
    FOR EACH ROW EXECUTE FUNCTION public.guard_payment_mutation();

COMMENT ON COLUMN public.payments.employee_id IS 'PAYEE-1a:这笔出款付给的是【员工】(报销)。direction=''out'' 时与 supplier_id 恰一非空;direction=''in'' 时必须为空 —— 收款不会收自员工(那是另一回事,不在本刀范围)。';

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "payments select by permission"
    ON public.payments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "payments insert by permission"
    ON public.payments
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.payments.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';
