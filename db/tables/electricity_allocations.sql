-- db/tables/electricity_allocations.sql
-- MES-5a-2(2026-10-08,MES-0 Q26 · Q27;MES-5a Step 0 Q21–Q28 · Q30,Tim):【一张电费单的分摊 —— 它就是这张账单【唯一】的一笔】。
--   一行 = 一张账单:哪一段时间(period_from–period_to)、哪一天的账单(bill_date)、账单号、供应商、金额、账单上的 kWh。
--   post_electricity_allocation 在【一笔事务】里(Q24):
--     ① 把账单记成一张费用单(expenses,EXP-…;未付 = 应付挂供应商,之后走付款申请 —— Q29;已付 = 银行)—— 账单在总账上只出现一次;
--     ② 给它覆盖的每一炉写一条实际电费成本行(processing_cost_entries,electricity,is_estimate = false)—— 那一条自己的录入分录照旧
--        借 5110 / 贷 2200(fin_journal_cost_entry);
--     ③ 用它自己的一张分录把这些行结掉:借 2200(各炉份额之和)· 借 6200(不计量 / 共用池 / 有表无单的余数)· 贷 应付或银行(账单全额);
--        成本行同时标成已结(remitted_at = 账单日、remitted_journal_entry_id = 这张分录),于是谁都改不了、删不掉它;
--     ④ 冲掉同一批炉上手敲的电费估计(没结过的那几条):标 relieved_at / relief_expense_id,并【软删】—— 一炉不能同时带着估计与实际
--        (Q24 "so no run carries both")。软删照旧过一张冲销分录(借 2200 / 贷 5110)。没被覆盖的炉上的估计一条都不动(Q26)。
--   【分账的规则只住在一处】electricity_allocation_compute —— 预览(preview_electricity_allocation)与过账共用它(AGENTS.md
--     「一个预览的屏幕问数据库」)。分给每一炉的 kWh 与依据在 electricity_allocation_lines 里,一行一炉。
--   【本位币】只收本位币的账单(currencies.is_base;Q28),外币按名拒 ELECTRICITY_BILL_CURRENCY_NOT_BASE。currency 照存那一刻的本位币。
--   【时间段不许重叠】同一段时间的电不许被两张账单各摊一次(ELECTRICITY_PERIOD_OVERLAPS)。
--   【金额遮蔽】bill_amount · price_per_kwh · allocated_amount · overhead_amount · relieved_estimate_amount 只经
--     electricity_allocations_masked 读(data.view_prices,Q30)—— 列清单授权里没有它们。kWh 不遮。
--   【只追加】没有 UPDATE / DELETE(语句级拒)。这一刀【没有】撤销一次分摊的路(交回 §6;它的费用单被 reverse_expense 按名拒,
--     EXPENSE_IS_ELECTRICITY_ALLOCATION —— 冲掉费用单而留着已结的成本行,2200 就对不上了)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.electricity_allocations (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    period_from               date NOT NULL,
    period_to                 date NOT NULL,
    bill_date                 date NOT NULL,
    invoice_ref               text NOT NULL CHECK (btrim(invoice_ref) <> ''),
    supplier_id               uuid REFERENCES public.suppliers (id),
    payee_name                text,
    currency                  text NOT NULL REFERENCES public.currencies (code),
    bill_amount               numeric NOT NULL CHECK (bill_amount > 0),
    bill_kwh                  numeric NOT NULL CHECK (bill_kwh > 0),
    price_per_kwh             numeric NOT NULL,
    metered_kwh               numeric NOT NULL CHECK (metered_kwh >= 0),
    allocated_kwh             numeric NOT NULL CHECK (allocated_kwh >= 0),
    shared_pool_kwh           numeric NOT NULL CHECK (shared_pool_kwh >= 0),
    unallocated_metered_kwh   numeric NOT NULL CHECK (unallocated_metered_kwh >= 0),
    unmetered_kwh             numeric NOT NULL CHECK (unmetered_kwh >= 0),
    allocated_amount          numeric NOT NULL CHECK (allocated_amount >= 0),
    overhead_amount           numeric NOT NULL CHECK (overhead_amount >= 0),
    relieved_estimate_amount  numeric NOT NULL DEFAULT 0 CHECK (relieved_estimate_amount >= 0),
    relieved_estimate_count   integer NOT NULL DEFAULT 0 CHECK (relieved_estimate_count >= 0),
    payment_status            text NOT NULL CHECK (payment_status IN ('paid', 'unpaid')),
    bank_account_code         text,
    expense_id                uuid NOT NULL UNIQUE REFERENCES public.expenses (id),
    journal_entry_id          uuid NOT NULL REFERENCES public.journal_entries (id),
    notes                     text,
    created_at                timestamptz NOT NULL DEFAULT now(),
    created_by                uuid DEFAULT auth.uid(),
    CONSTRAINT electricity_allocations_period CHECK (period_from <= period_to),
    CONSTRAINT electricity_allocations_amounts CHECK (allocated_amount + overhead_amount = bill_amount),
    CONSTRAINT electricity_allocations_kwh CHECK (allocated_kwh + shared_pool_kwh + unallocated_metered_kwh = metered_kwh
                                                  AND metered_kwh + unmetered_kwh = bill_kwh),
    CONSTRAINT electricity_allocations_payment_shape
        CHECK ((payment_status = 'paid' AND bank_account_code IS NOT NULL)
               OR (payment_status = 'unpaid' AND bank_account_code IS NULL AND supplier_id IS NOT NULL))
);

COMMENT ON TABLE public.electricity_allocations IS
    'MES-5a-2:一张电费单的分摊 —— 它就是这张账单唯一的一笔(Q24):一张费用单、每一炉一条实际电费成本行、一张把它们结掉的分录(借 2200 份额 · 借 6200 余数 · 贷 应付或银行)、同一批炉上手敲的估计被冲掉并软删。规则只在 electricity_allocation_compute(预览与过账共用)。只收本位币;时间段不许重叠;金额只经 _masked 视图读(data.view_prices);只追加,本刀没有撤销的路。';
COMMENT ON COLUMN public.electricity_allocations.overhead_amount IS
    '留在间接费用 6200 的那一份 = 账单金额 − 分给各炉的金额:不计量的电(账单 kWh − 量到的 kWh)、共用池电表量到的电(V25 没给之前)、有表的机器在这段时间里没有一炉的电、以及分到分的尾差。';
COMMENT ON COLUMN public.electricity_allocations.unallocated_metered_kwh IS
    '有电表的机器量到了、却没有分给任何一炉的 kWh(那段时间那台机器一炉都没有,或量不出来的机器不算 —— 后者算在 unmetered_kwh 里)。';

CREATE INDEX electricity_allocations_supplier_id_rel ON public.electricity_allocations (supplier_id);
CREATE INDEX electricity_allocations_journal_entry_id_rel ON public.electricity_allocations (journal_entry_id);
CREATE INDEX electricity_allocations_period ON public.electricity_allocations (period_from, period_to);

CREATE TRIGGER trg_electricity_allocations_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.electricity_allocations
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.electricity_allocations ENABLE ROW LEVEL SECURITY;
-- 读:财务(分摊页)或加工(加工单页上"这一炉分到的电"链回这张账单)。金额走遮蔽视图。写只经函数。
CREATE POLICY "electricity_allocations select by permission" ON public.electricity_allocations
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.finance.view'::text, 'module.processing.view'::text]));

-- 字段级遮蔽:先整表收回,再把不敏感的列逐列授回(五列金额只经 electricity_allocations_masked 读)。
-- 【加列必改这一行,并且同时改 _masked 视图】(AGENTS.md「Adding a column to a masked table」:三件事一支迁移)。
REVOKE SELECT ON public.electricity_allocations FROM authenticated, anon;
GRANT SELECT (id, period_from, period_to, bill_date, invoice_ref, supplier_id, payee_name, currency, bill_kwh,
              metered_kwh, allocated_kwh, shared_pool_kwh, unallocated_metered_kwh, unmetered_kwh, relieved_estimate_count,
              payment_status, bank_account_code, expense_id, journal_entry_id, notes, created_at, created_by)
    ON public.electricity_allocations TO authenticated;
REVOKE ALL ON public.electricity_allocations FROM anon;
