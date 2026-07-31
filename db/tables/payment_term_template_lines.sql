-- db/tables/payment_term_template_lines.sql
-- 模板的期次行。形状与 purchase_order_payment_terms 一致(同样的 XOR 与取值范围),
-- 只有一处不同:
--
--   days_offset —— 模板【不可能知道具体日期】,所以 'fixed_date' 那类期次在模板里存
--   的是"相对下单日多少天",由 apply_payment_term_template 在套用时换算成 due_date
--   (order_date + days_offset)。这也是模板行没有 due_date 列的原因。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.payment_term_template_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id      uuid NOT NULL REFERENCES public.payment_term_templates (id) ON DELETE CASCADE,
    seq              integer NOT NULL,
    label            text NOT NULL,
    percentage       numeric CHECK (percentage IS NULL OR (percentage > 0 AND percentage <= 100)),
    fixed_amount_usd numeric CHECK (fixed_amount_usd IS NULL OR fixed_amount_usd > 0),
    CONSTRAINT ptt_lines_pct_xor_fixed CHECK (num_nonnulls(percentage, fixed_amount_usd) = 1),
    trigger_event    text NOT NULL
                     CHECK (trigger_event IN ('on_order','on_shipment','on_arrival','post_assay','fixed_date')),
    days_offset      integer,
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (template_id, seq)
);

CREATE INDEX idx_ptt_lines_template ON public.payment_term_template_lines (template_id);

ALTER TABLE public.payment_term_template_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on payment_term_template_lines"
    ON public.payment_term_template_lines AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
