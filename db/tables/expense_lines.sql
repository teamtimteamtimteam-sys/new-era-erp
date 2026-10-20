-- db/tables/expense_lines.sql
-- EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q1–Q16):费用单的【行】。表头在 expenses(日期 · 收款方 · 币种 · 备注 · 单据合计),
-- 每一行在这里:自己的费用科目 · 税码 · 不含税净额 · 税 · 备注。
--
-- 【一张单 = 一张分录 = 一笔应付】(Tim)每一行在分录里各有自己的借方腿(科目 + 税码)与税腿(可抵的借 1400、不可抵的借进
--   这一行自己的科目),贷 2000 也按行各记一条净额、一条 'GST on <单号>' —— 所以每一行在本位币上自己就平,分录不会因为
--   "合计先四舍五入"差出一分钱(post_journal_entry 逐行 round)。应付只有一笔:付款、定金冲抵、报销单读的都是表头。
-- 【税按行算】(Q16)每一行各自 round —— 与供应商按整张单算的税可能差一分钱,Tim 接受,不设改写栏。
-- 【混税码可以】(Q2)同一张单上可抵与不可抵的行可以并存;唯一的例外:要代扣预提税的单据【任何一行】都不许带 GST
--   (EXPENSE_WHT_WITH_GST,按单据判,与此前一样)。
-- 【资本支出单恰好一行】(Q1)科目 1500 的那一行只能是单据唯一的一行,与普通行混装按名拒(EXPENSE_CAPITAL_SOLE_LINE);
--   资产、采购单行与维修资本化的链接因此仍挂在表头。按行资本化是另一刀(docs/forward-queue.md,已停放)。
-- 【不可改、不可删】与表头同一条:更正走冲销(整张单,Q4)。冲销镜像单带着同样的行(科目 + 净额,不带税码,与镜像表头一致)。
-- 【读】持 module.finance.view(与表头同一条);【写】只经 record_expense_document 与那几支系统写入者(电费分摊 · 加工费结算 ·
--   冲销),表上那条 INSERT 策略与表头逐字同形 —— 直插一行进旧表头会在提交时被 guard_expense_totals 拒掉。

CREATE TABLE public.expense_lines (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    expense_id    uuid NOT NULL REFERENCES public.expenses (id),
    line_no       integer NOT NULL CHECK (line_no >= 1),
    account_code  text NOT NULL REFERENCES public.accounts (code),
    amount_ccy    numeric NOT NULL CHECK (amount_ccy > 0),   -- 这一行的【不含税净额】,单据币种
    amount_base   numeric NOT NULL,                          -- round(amount_ccy × 表头 fx_rate, 2)
    tax_code      text REFERENCES public.tax_codes (code),
    tax_rate_pct  numeric,
    tax_ccy       numeric NOT NULL DEFAULT 0,
    tax_base      numeric NOT NULL DEFAULT 0,
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    CONSTRAINT expense_lines_line_no_unique UNIQUE (expense_id, line_no),
    -- 【四列是一件事】原来表头上 expenses_tax_shape + expenses_tax_ccy_shape 两条说的,现在逐行说。
    CONSTRAINT expense_lines_tax_shape CHECK (
        (tax_code IS NULL     AND tax_rate_pct IS NULL     AND tax_ccy = 0  AND tax_base = 0)
     OR (tax_code IS NOT NULL AND tax_rate_pct IS NOT NULL AND tax_ccy >= 0 AND tax_base >= 0))
);

COMMENT ON TABLE public.expense_lines IS
    'EXPENSE-MULTILINE-1(Tim 2026-10-20):费用单的行 —— 每一行自己的科目、税码、不含税净额、税与备注。表头(expenses)的四个合计由 guard_expense_totals 强制等于各行之和;行不可改、不可删。资本支出单恰好一行(Q1)。';

CREATE INDEX expense_lines_account_code ON public.expense_lines (account_code);

-- 不可改、不可删(与 guard_expense_mutation 同一条:更正走冲销)
CREATE OR REPLACE FUNCTION public.guard_expense_line_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'EXPENSE_LINE_IMMUTABLE';
END;
$function$;

CREATE TRIGGER trg_expense_lines_immutable
    BEFORE UPDATE OR DELETE ON public.expense_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_line_mutation();

-- GST-2 那道闸,随税码从表头搬过来:未注册时写不进税码(与 invoice_lines / credit_note_lines 同一支函数)
CREATE TRIGGER trg_expense_lines_tax_code_registered
    BEFORE INSERT OR UPDATE OF tax_code ON public.expense_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_document_tax_code();

-- 表头合计 = 各行之和(guard_expense_totals 住在 db/tables/expenses.sql;两张表各挂一条,同一支函数)
CREATE CONSTRAINT TRIGGER trg_expense_lines_totals_match
    AFTER INSERT ON public.expense_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_totals();

ALTER TABLE public.expense_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "expense_lines select by permission"
    ON public.expense_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "expense_lines insert by permission"
    ON public.expense_lines
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

REVOKE ALL ON public.expense_lines FROM anon;
