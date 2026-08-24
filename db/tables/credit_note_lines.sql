-- db/tables/credit_note_lines.sql
-- CN-1:贷项凭证的行 —— 一行冲一张发票行的一部分,类型决定它过到哪个科目。
--
-- NOTE: introduced by db/migrations/2026-08-15-cn1-credit-note.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.credit_note_lines (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    credit_note_id uuid NOT NULL REFERENCES public.credit_notes (id),
    -- 【指向发票行,不指向订单行】这张凭证冲的是【那张发票上的那一行】——
    -- 上限也是按发票行算的(未释放的负债 / 已释放的收入)。订单行是它背后的
    -- 履约主语,但客户手里那张纸上写的是发票行。
    invoice_line_id uuid NOT NULL REFERENCES public.invoice_lines (id),
    -- 【两种行过的账完全不同 —— 见迁移抬头】
    --   unshipped_cancel  未发的那部分:还躺在 2500 里,从来没变成收入 → 借 2500
    --   revenue_reduction 已发的那部分减价/折让:收入已经认了 → 借 4000
    kind           text NOT NULL CHECK (kind IN ('unshipped_cancel','revenue_reduction')),
    -- 【数量可空,而且这不是偷懒】取消未发的那部分时,数量是一个真事实(少发几件);
    -- 而一次减价/质量折让往往【不对应任何数量】(整批降 2%、一次性折让),
    -- 硬要一个数量就得编一个。金额才是这张单据的主语,所以只有它 NOT NULL。
    qty            numeric CHECK (qty IS NULL OR qty > 0),
    amount         numeric NOT NULL CHECK (amount > 0),
    created_at     timestamptz NOT NULL DEFAULT now(),
    -- ── GST-2 追加的列(ALTER 加的列排在末尾)────────────────────────────────
    -- 【从被冲的那一张发票行【抄】来,不重新解析】冲的是哪一笔供应,就退哪一笔
    -- 供应的税,连它当时那个税率一起 —— 即便法定税率此后变过。按凭证日重算,
    -- 会用今天的税率去退一笔按去年税率收过的税,差额无声地留在 2100 里。
    -- 与"币种与汇率抄发票的"逐字同一条理由(见本文件抬头与 CN-1 迁移抬头)。
    -- 一张贷项凭证在 F5 上是一笔【负的供应】:它减 box1,也减 box6。
    tax_code       text REFERENCES public.tax_codes (code),
    tax_rate_pct   numeric,
    tax_base       numeric NOT NULL DEFAULT 0,
    CONSTRAINT credit_note_lines_tax_shape CHECK (
        (tax_code IS NULL     AND tax_rate_pct IS NULL     AND tax_base = 0)
     OR (tax_code IS NOT NULL AND tax_rate_pct IS NOT NULL AND tax_base >= 0))
);

COMMENT ON TABLE public.credit_note_lines IS
    'CN-1:贷项凭证的行 —— 一行冲【一张发票行】的一部分。kind 决定它过到哪个科目:unshipped_cancel 冲的是【还躺在 2500 里、从来没变成收入】的那部分(货没发出去),revenue_reduction 冲的是【已经交付、收入已认】的那部分(事后减价/质量折让)。两者都贷 1100。把它们合成一种就会让短装去借 4000 —— 那等于把一次正确的交付说成少卖了。qty 可空是有意的:取消未发部分时数量是真事实,而一次整批折让往往不对应任何数量,硬要就得编一个;金额才是主语。只增不改。';

COMMENT ON COLUMN public.credit_note_lines.amount IS
    'CN-1:本行冲减的金额,以【单据币种】计(= 发票的币种,凭证从发票抄过来)。本位币额不存 —— 它是 amount × credit_notes.fx_rate,而那个汇率也是抄来的:存第二份就是给同一个数留两个会漂开的写法(invoice_document_totals 的同一条理由)。';

CREATE INDEX idx_credit_note_lines_note ON public.credit_note_lines (credit_note_id);
CREATE INDEX idx_credit_note_lines_invoice_line ON public.credit_note_lines (invoice_line_id);

CREATE TRIGGER trg_credit_note_lines_append_only
    BEFORE UPDATE OR DELETE ON public.credit_note_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_append_only();

-- 【行必须属于它冲的那张发票】否则一张凭证可以冲到别人的发票行上,
-- 而三条天花板全是按发票行算的 —— 那等于把它们一起绕过去。
CREATE TRIGGER trg_credit_note_lines_belongs
    BEFORE INSERT ON public.credit_note_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_line_belongs();

ALTER TABLE public.credit_note_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "credit_note_lines select by permission" ON public.credit_note_lines
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));

-- GST-2:未注册时写不进税码(与 invoice_lines / expenses 同一道闸)。
CREATE TRIGGER trg_credit_note_lines_tax_code_registered
    BEFORE INSERT OR UPDATE OF tax_code ON public.credit_note_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_document_tax_code();

COMMENT ON COLUMN public.credit_note_lines.tax_code IS
    'GST-2:贷项凭证行的税码,【从它冲的那一张发票行抄来】—— 不重新解析。冲的是哪一笔供应,就退哪一笔供应的税,连税率一起,即便法定税率此后变过。一张贷项凭证在 F5 上是一笔【负的供应】。';
