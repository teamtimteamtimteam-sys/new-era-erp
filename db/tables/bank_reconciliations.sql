-- db/tables/bank_reconciliations.sql
-- BANK-REC:**一次对账 = 一行,而那一行是抄下来的。**
--
-- 对账那一刻把三个数字冻在这里:银行的 closing_balance、该科目在 period_end 的
-- 账面余额、以及两者的差额。此后底下的分录再动,这一行也不动 ——
-- 与 gst_return_boxes(报出去的那一份)同一条规矩,理由也是同一个:
-- 「我们当时是照着什么对上的」与「今天重算是多少」是两个问题,日后有人问的
-- 一定是前一个。只留一个重算式,等于宣称这两个问题永远同一个答案。
--
-- 【为什么是一张表,不是 bank_statements 上的几个列】unreconcile_statement 一直
-- 都在:重开、改完、再对一次,是正常的更正路径。三个数字挂在列上时,第二次对账
-- 会【原地覆盖第一次签下的那一份】—— 而更正必须是一个新事件,不是一次编辑。
-- 一行一次事件,历史自己就留下来了;掀掉的那一份落 superseded_at + 理由,不删。
--
-- 【队列要的"每月记录"因此是白拿的】银行余额、账面余额、差额、说明 ——
-- 一次对账一行,报表本来就按月,不需要事后拼。读它走 bank_reconciliation_record。
--
-- 写入只走 reconcile_statement / unreconcile_statement(SECURITY DEFINER),
-- 所以这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-26-bankrec-balance-agreement-and-the-explained-difference.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.bank_reconciliations (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    statement_id         uuid NOT NULL REFERENCES public.bank_statements (id) ON DELETE RESTRICT,
    as_of                date NOT NULL,              -- = 报表的 period_end
    currency             text NOT NULL REFERENCES public.currencies (code),
    bank_closing_balance numeric NOT NULL,
    book_balance         numeric NOT NULL,
    difference           numeric NOT NULL,
    -- 【差额不能被存成与两个余额不一致】否则这一行自己就能自相矛盾。
    CONSTRAINT bank_reconciliations_difference_consistent
        CHECK (difference = book_balance - bank_closing_balance),
    matched_lines        integer NOT NULL CHECK (matched_lines >= 0),
    ignored_lines        integer NOT NULL CHECK (ignored_lines >= 0),
    reconciled_at        timestamptz NOT NULL DEFAULT now(),
    reconciled_by        uuid DEFAULT auth.uid(),
    -- 被 unreconcile 掀掉时落下。**不删行** —— 签过的那一份留着。
    superseded_at        timestamptz,
    superseded_reason    text,
    CONSTRAINT bank_reconciliations_superseded_shape CHECK (
        (superseded_at IS NULL     AND superseded_reason IS NULL)
     OR (superseded_at IS NOT NULL AND btrim(COALESCE(superseded_reason,'')) <> '')
    ),
    created_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_bank_reconciliations_statement ON public.bank_reconciliations (statement_id);
-- 一张报表【同时】只能有一份未被掀掉的对账
CREATE UNIQUE INDEX uq_bank_reconciliations_live
    ON public.bank_reconciliations (statement_id) WHERE superseded_at IS NULL;

-- 【不可改】唯一合法的变更是 superseded_at/reason 从空到有,且只有一次。
-- 与 journal_entries 的 posted→reversed 同一手法(逐列比对)。
CREATE OR REPLACE FUNCTION public.guard_bank_reconciliation_immutable()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'RECONCILIATION_IMMUTABLE';
    END IF;
    IF NOT (OLD.superseded_at IS NULL AND NEW.superseded_at IS NOT NULL) THEN
        RAISE EXCEPTION 'RECONCILIATION_IMMUTABLE';
    END IF;
    -- 除这两列外任何列变更 → 拒绝
    IF (NEW.id, NEW.statement_id, NEW.as_of, NEW.currency, NEW.bank_closing_balance,
        NEW.book_balance, NEW.difference, NEW.matched_lines, NEW.ignored_lines,
        NEW.reconciled_at, NEW.reconciled_by, NEW.created_at)
       IS DISTINCT FROM
       (OLD.id, OLD.statement_id, OLD.as_of, OLD.currency, OLD.bank_closing_balance,
        OLD.book_balance, OLD.difference, OLD.matched_lines, OLD.ignored_lines,
        OLD.reconciled_at, OLD.reconciled_by, OLD.created_at) THEN
        RAISE EXCEPTION 'RECONCILIATION_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_bank_reconciliations_immutable
    BEFORE UPDATE OR DELETE ON public.bank_reconciliations
    FOR EACH ROW EXECUTE FUNCTION public.guard_bank_reconciliation_immutable();

ALTER TABLE public.bank_reconciliations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bank_reconciliations select by permission"
    ON public.bank_reconciliations
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
