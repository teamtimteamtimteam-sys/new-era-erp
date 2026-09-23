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

-- SEARCH-4 · 迁移 B:关联搜索走这一列。为将来的体量建,不为今天的毫秒数
--(320 行上规划器一律 Seq Scan;理由与迁移 A/C 逐字同族)。
CREATE INDEX bank_transfers_journal_entry_id_rel ON public.bank_transfers (journal_entry_id);
CREATE INDEX bank_transfers_reversal_entry_id_rel ON public.bank_transfers (reversal_entry_id);

ALTER TABLE public.bank_transfers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bank_transfers select by permission"
    ON public.bank_transfers AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
-- ★ PAY-REQ-1(Tim 的 Q2(a),2026-09-23):写策略(INSERT 与 UPDATE)已拆除。
--   它们让持 module.finance.edit 的人不经 record_bank_transfer / reverse_bank_transfer
--   直接写这张表(插一行没有分录的转账、把 reversed_at 改掉)。两支函数都是
--   SECURITY DEFINER,以属主身份写,不需要策略。转账本身的批准在 PAY-REQ-1 Batch B。

COMMENT ON TABLE public.bank_transfers IS
    '行内转账。两边金额照银行实际;分录两条银行线各记本币,供两边对账单各自认领。PAY-REQ-1 Batch B 起:转账与其冲销都经付款申请(提 → CFO 批 → 执行),执行时调 record_bank_transfer_internal / reverse_bank_transfer_internal。';

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.bank_transfers
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');
