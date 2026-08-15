-- db/tables/credit_notes.sql
-- CN-1:贷项凭证单据头 —— 把客户欠的钱减下来的那张单据。
--
-- NOTE: introduced by db/migrations/2026-08-15-cn1-credit-note.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.credit_notes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL UNIQUE,          -- 'CN-YYYY-NNNN',无缝,自己的咨询锁
    -- 【绑一张发票,而且只绑一张】跨发票的抵扣要回答"先抵哪一张",那是核销的
    -- 语义,不是贷项凭证的。NOT NULL:一张不指向任何发票的贷项凭证,就是一个
    -- 没有上限的减记。
    invoice_id  uuid NOT NULL REFERENCES public.invoices (id),
    -- 【理由必填】一张减了客户欠款的单据没有理由,三个月后没有人说得出为什么。
    reason      text NOT NULL,
    -- 【物理事件日,永不默认】(AGENTS.md 的日期规矩)它决定这笔冲销落进哪个
    -- 会计期间;补一个 CURRENT_DATE 会让"留空"比"填对"更容易通过 —— 今天的日期
    -- 永远撞不上 PERIOD_LOCKED,于是填对了反而被拒。
    note_date   date NOT NULL,
    -- 【过账单据:分录先出,再写这一行】所以 NOT NULL —— 与 invoices 的
    -- kind='order' 那一支同形(那里也是 entry_id NOT NULL)。
    entry_id    uuid NOT NULL REFERENCES public.journal_entries (id),
    -- 【币种与汇率是从发票【抄】过来的,不是调用方递进来的】见抬头那一段:
    -- 结算解除按的就是这个基准,用别的会凭空造出一笔已实现汇兑。
    -- 守卫 guard_credit_note_invoice 对着发票逐列核对,抄错了当场拒。
    currency    text NOT NULL REFERENCES public.currencies (code),
    fx_rate     numeric NOT NULL CHECK (fx_rate > 0),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.credit_notes IS
    'CN-1:贷项凭证 —— 发票开出去之后、又不能再作废的时候,把客户欠的钱减下来的那张单据(九处"更正走贷项凭证"停放的就是它)。【只对 kind=''order'' 的发票】:那种发票自己就是应收单据、开票即过账;sale 型什么都不过账,应收长在不可变的 sales_records 上,那是另一套东西,它今天的路仍然是 void_invoice / reverse_payment。一张凭证绑一张发票,总额以那张发票【当下的】开放余额为上限 —— 超出的那一半是【退款】,而退款需要一个这个系统还没有的客户贷余概念(CN_INVOICE_FULLY_SETTLED 按名拒)。币种与汇率【抄发票的】:1100/2500/4000 都是按它入的账,换个汇率冲会在本位币上留下一截与真实已实现汇兑长得一模一样、却没有任何钱动过的残渣。只增不改(CREDIT_NOTE_IMMUTABLE)—— 作废是停放的概念,见迁移抬头。';

COMMENT ON COLUMN public.credit_notes.note_date IS
    'CN-1:这张贷项凭证的【单据日】—— 物理事件日,必填、永不默认。它决定冲销分录落进哪个会计期间,而期间锁与年结闸由 post_journal_entry 对它统一执行(锁住的月份按名拒,不是悄悄挪到今天)。给它一个 CURRENT_DATE 默认值会让【留空】比【填对】更容易通过:今天的日期永远撞不上 PERIOD_LOCKED。';

CREATE INDEX idx_credit_notes_invoice ON public.credit_notes (invoice_id);
CREATE INDEX idx_credit_notes_date    ON public.credit_notes (note_date DESC);

CREATE TRIGGER trg_credit_notes_append_only
    BEFORE UPDATE OR DELETE ON public.credit_notes
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_append_only();

-- 【发票的 kind / 币种 / 汇率由触发器把关,不只写在函数里】CHECK 看不见另一张表
-- (FIN-29 为这条写过一整段),而守卫不该依赖"今天只有一个调用方"。
CREATE TRIGGER trg_credit_notes_invoice_guard
    BEFORE INSERT ON public.credit_notes
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_invoice();

ALTER TABLE public.credit_notes ENABLE ROW LEVEL SECURITY;

-- 【没有 INSERT 策略,这是刻意的】唯一写入口是 create_credit_note(属主权限,
-- 同一个事务里过账 + 写单头 + 写行)。留着侧门,下一个人照样可以插一张
-- 【没有分录、不受任何天花板约束】的凭证 —— 与 SO-2b 撤掉建单 INSERT 策略同理。
-- 【为什么是 module.finance.*】开票是财务的动作(create_order_invoice 要
-- module.finance.edit),而贷项凭证是它的反面 —— 它直接改总账与应收。
CREATE POLICY "credit_notes select by permission" ON public.credit_notes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));
