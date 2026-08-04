-- db/tables/bank_transfers.sql
-- 行内转账:自己账户之间挪钱,不是付给任何人(FIN-1b)。
--
-- 【两边金额都照银行水单原样录】(FIN-0 C4:实际兑换用实际数,永远不用牌价折另一边)。
-- 【分录必须两条银行线,各记各的本币】—— 两个账户各自收对账单,各自要认领自己那条;
-- 轧成一条净额会让其中一张对账单永远对不平,这正是本切存在的理由。
-- 跨币种时贷方外币线的 fx 取【本笔的实际隐含汇率】(= 对方实际金额 ÷ 本方实际金额),
-- 于是分录恰好配平、不出汇兑损益行 —— 与均价的已实现差异归属(转账时点认列 vs
-- 期末重估)是 FIN-1b Part C 的会计政策问题,待定;本表不预设答案。
-- 【更正靠冲销,不靠改】reverse_bank_transfer;行不可改(仅 reversed_* 例外)。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin1b-bank-transfers.sql.

CREATE TABLE public.bank_transfers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_date    date NOT NULL,
    from_account     text NOT NULL CHECK (from_account IN ('1000','1010')),
    to_account       text NOT NULL CHECK (to_account IN ('1000','1010')),
    amount_out       numeric NOT NULL CHECK (amount_out > 0),   -- 源账户本币,照水单
    amount_in        numeric NOT NULL CHECK (amount_in > 0),    -- 目标账户本币,照水单
    bank_reference   text,
    notes            text,
    journal_entry_id uuid NOT NULL REFERENCES public.journal_entries (id),
    reversed_at      timestamptz,
    reversed_by      uuid,
    reversal_entry_id uuid REFERENCES public.journal_entries (id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    CONSTRAINT bank_transfers_not_self CHECK (from_account <> to_account)
);

CREATE INDEX idx_bank_transfers_date ON public.bank_transfers (transfer_date);

ALTER TABLE public.bank_transfers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bank_transfers select by permission"
    ON public.bank_transfers AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
CREATE POLICY "bank_transfers insert by permission"
    ON public.bank_transfers AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));
CREATE POLICY "bank_transfers update by permission"
    ON public.bank_transfers AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

COMMENT ON TABLE public.bank_transfers IS
    '行内转账。两边金额照银行实际;分录两条银行线各记本币,供两边对账单各自认领。更正靠 reverse_bank_transfer。';
