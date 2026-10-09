-- db/tables/electricity_allocation_reversals.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q22 · Q23 · Q32 · Q34,Tim):【一张电费单的撤回 —— 一张分摊最多一行】。
--   reverse_electricity_allocation 在【一笔事务、一个冲销日】里(Q22):
--     ① 冲掉那张费用单与它的分录(reverse_expense_internal —— reverse_expense 用的同一段;已付的那一张借回银行,未付的借回 2000);
--     ② 每一炉那条已结的实际电费行:先清掉结算戳(remitted_*),再软删 —— 软删照旧过一张 借 2200 / 贷 5110(fin_journal_cost_entry);
--     ③ 被它冲掉的每一条手敲估计:先清掉冲抵戳(relieved_at / relief_expense_id),再【取消软删】,再明写一张 借 5110 / 贷 2200 的
--        重新计提(取消软删不过账 —— fin_journal_cost_entry 只认"软删"与"改额"两种);
--     ④ 写这一行。
--   于是 2200 · 5110 · 6200 · 2000(或银行)回到分摊之前的余额,而那几炉回到分摊之前的样子 —— 可以再过一张改正过的账单(Q23)。
--   【一张分摊最多撤一次】allocation_id 唯一;撤回过的分摊不再算进"这一炉已经分过""时间段重叠"(electricity_allocation_compute)与
--     "一炉只在一张没撤回的分摊里"(guard_electricity_line_one_live_allocation)。分摊与它的行仍然只追加 —— 撤回是这里多一行,不是改那里。
--   【理由必填】reason(btrim 非空;reverse_freight_document 的先例)。没有审批(Q25:费用单没有,冲销费用单也没有)。
--   【金额遮蔽】bill_amount · actual_line_amount · restored_estimate_amount 只经 electricity_allocation_reversals_masked 读
--     (data.view_prices,与分摊那五列同一条规矩;Q32)。件数不遮。
--   【只追加】UPDATE / DELETE / TRUNCATE 语句级拒(guard_append_only_log)。只经 reverse_electricity_allocation 写。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.electricity_allocation_reversals (
    id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    allocation_id              uuid NOT NULL UNIQUE REFERENCES public.electricity_allocations (id),
    reversal_date              date NOT NULL,
    reason                     text NOT NULL CHECK (btrim(reason) <> ''),
    reversal_expense_id        uuid NOT NULL UNIQUE REFERENCES public.expenses (id),
    reversal_journal_entry_id  uuid NOT NULL REFERENCES public.journal_entries (id),
    payment_status             text NOT NULL CHECK (payment_status IN ('paid', 'unpaid')),
    bank_account_code          text,
    bill_amount                numeric NOT NULL CHECK (bill_amount > 0),
    actual_line_count          integer NOT NULL CHECK (actual_line_count >= 0),
    actual_line_amount         numeric NOT NULL CHECK (actual_line_amount >= 0),
    restored_estimate_count    integer NOT NULL CHECK (restored_estimate_count >= 0),
    restored_estimate_amount   numeric NOT NULL,
    created_at                 timestamptz NOT NULL DEFAULT now(),
    created_by                 uuid DEFAULT auth.uid(),
    CONSTRAINT electricity_allocation_reversals_payment_shape
        CHECK ((payment_status = 'paid' AND bank_account_code IS NOT NULL) OR (payment_status = 'unpaid' AND bank_account_code IS NULL))
);

COMMENT ON TABLE public.electricity_allocation_reversals IS
    'MES-5b-2:一张电费单的撤回(一张分摊最多一行,理由必填)。同一笔事务、同一个冲销日:冲掉费用单与分录(已付的借回银行)· 每一炉的实际电费行清戳后软删(借 2200 / 贷 5110)· 被冲掉的估计清戳、取消软删、明写重新计提(借 5110 / 贷 2200)。之后可以为同一段时间再过一张改正过的账单。金额只经 _masked 视图读(data.view_prices);只追加。';
COMMENT ON COLUMN public.electricity_allocation_reversals.reversal_expense_id IS
    '冲销那张费用单时生出的镜像费用单(reverse_expense_internal 的 mirror;它不是新的应付,ap_open_items 按 reversed_by_expense 排除它)。';
COMMENT ON COLUMN public.electricity_allocation_reversals.reversal_journal_entry_id IS
    '分摊那张分录的冲销件(借 2000 或银行 / 贷 2200 · 贷 6200)。实际电费行的软删分录与估计的重新计提各自另有一张(source_type = processing_cost)。';
COMMENT ON COLUMN public.electricity_allocation_reversals.restored_estimate_amount IS
    '取消软删、重新计提回 2200 的手敲估计之和(= 分摊行的 relieved_estimate_amount)。不设符号检查 —— 估计与 processing_cost_entries.amount_base 一样可以为负。';

CREATE INDEX electricity_allocation_reversals_reversal_journal_entry_id_rel ON public.electricity_allocation_reversals (reversal_journal_entry_id);

CREATE TRIGGER trg_electricity_allocation_reversals_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.electricity_allocation_reversals
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.electricity_allocation_reversals ENABLE ROW LEVEL SECURITY;
-- 读:与分摊同一句(财务或加工查看码)。金额走遮蔽视图。写只经函数。
CREATE POLICY "electricity_allocation_reversals select by permission" ON public.electricity_allocation_reversals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.finance.view'::text, 'module.processing.view'::text]));

-- 字段级遮蔽:三列金额只经 electricity_allocation_reversals_masked 读。【加列必改这一行,并且同时改 _masked 视图】
REVOKE SELECT ON public.electricity_allocation_reversals FROM authenticated, anon;
GRANT SELECT (id, allocation_id, reversal_date, reason, reversal_expense_id, reversal_journal_entry_id, payment_status, bank_account_code,
              actual_line_count, restored_estimate_count, created_at, created_by)
    ON public.electricity_allocation_reversals TO authenticated;
REVOKE ALL ON public.electricity_allocation_reversals FROM anon;
