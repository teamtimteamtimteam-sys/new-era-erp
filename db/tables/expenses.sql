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
    amount_base          numeric NOT NULL,  -- round(amount_ccy × fx_rate, 2)
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
    -- ── PAYEE-1a 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 往来对象的【另一半】:这笔费用欠的是员工(报销)。详见列注释。
    employee_id         uuid REFERENCES public.employees (id),
    -- PAYEE-1a:往来对象【二选一】。两句话,刻意分开写:
    --   * 【从不两个】任何状态下都不许同时挂供应商与员工 —— 一笔钱不可能
    --     同时欠着两个人,悄悄挑一个会让另一个人的账凭空消失;
    --   * 【必有一个】只有 unpaid 才要求 —— 已付费用不产生应付,线上 2 笔 paid
    --     的 supplier_id 本来就是空的(实测)。把两句合成一句 `= 1`
    --     会把它们全部挡下(fixture 90 的 I 臂钉这一条)。
    CONSTRAINT expenses_counterparty_shape CHECK (
        num_nonnulls(supplier_id, employee_id) <= 1
        AND (
            (payment_status = 'paid' AND bank_account_code IS NOT NULL)
            OR (payment_status = 'unpaid'
                AND num_nonnulls(supplier_id, employee_id) = 1
                AND bank_account_code IS NULL)
        )
    )
);

COMMENT ON COLUMN public.expenses.employee_id IS 'PAYEE-1a:这笔费用欠的是【员工】(报销)。与 supplier_id 恰一非空 —— 一笔钱不可能同时欠着供应商和员工。
【它取代了 payee_name 那个自由文本吗?不完全】payee_name 仍在,它记的是"付给谁"的字面说法(FIN-26 的旧行、或一次性收款人);employee_id 是【一个指向真人的外键】,应付账因此能按人分行、能被点开。两者并存时以 employee_id 为准。
【为什么不是继续用假供应商】"Staff Reimbursements" 那个往来户把所有员工的欠款汇成一行,AP 账龄上分不出是谁、也点不开。它是 expenses_payment_shape 这条 CHECK 逼出来的变通,而本刀移除了那个必要性。';

CREATE INDEX idx_expenses_date ON public.expenses (expense_date);
CREATE INDEX idx_expenses_supplier ON public.expenses (supplier_id);
CREATE INDEX idx_expenses_payment_status ON public.expenses (payment_status);

-- 守卫:只放行 posted→reversed 且首挂 reversed_by_expense,其余列逐列锁死
CREATE OR REPLACE FUNCTION public.guard_expense_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
       OR NEW.amount_base          IS DISTINCT FROM OLD.amount_base
       OR NEW.payment_status      IS DISTINCT FROM OLD.payment_status
       OR NEW.bank_account_code   IS DISTINCT FROM OLD.bank_account_code
       OR NEW.supplier_id         IS DISTINCT FROM OLD.supplier_id
       -- PAYEE-1a fu1:往来对象的另一半,补进这份清单是为了【让清单完整】。
       -- 注意:即使少了这一行,下面那句"只放行 过账→冲销"的兜底也会拒掉
       -- 任何别的 UPDATE(实测过)—— 所以这不是在补洞,是在让这份
       -- 声称完整的枚举名副其实。两道闸各自独立,兜底放宽时清单就是唯一那道。
       OR NEW.employee_id         IS DISTINCT FROM OLD.employee_id
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
$function$;

CREATE TRIGGER trg_expenses_immutable
    BEFORE UPDATE OR DELETE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_mutation();

ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "expenses select by permission"
    ON public.expenses
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "expenses insert by permission"
    ON public.expenses
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.expenses.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';
