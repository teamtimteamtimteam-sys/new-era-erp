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
    fixed_amount_ccy numeric CHECK (fixed_amount_ccy IS NULL OR fixed_amount_ccy > 0),
    CONSTRAINT ptt_lines_pct_xor_fixed CHECK (num_nonnulls(percentage, fixed_amount_ccy) = 1),
    trigger_event    text NOT NULL
                     CHECK (trigger_event IN ('on_order','on_shipment','on_arrival','post_assay','fixed_date')),
    days_offset      integer,
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (template_id, seq)
);

COMMENT ON COLUMN public.payment_term_template_lines.fixed_amount_ccy IS
    '模板里该期的定额,币种由【模板头】payment_term_templates.currency 声明(FIN-29)。有定额腿就必须声明,而套用时只接受币种相同的采购单 —— 不换算。FIN-29 之前这一列没有币种可言:同一个模板套到 USD 单与 SGD 单上,同一个数字是两笔差着一个汇率的钱。FIN-28 前列名 fixed_amount_usd。';

-- FIN-29:插/改定额腿时,模板头必须已声明币种(守卫函数在
-- db/functions/guard_template_fixed_needs_currency.sql)。
CREATE TRIGGER trg_ptt_lines_fixed_needs_currency
    BEFORE INSERT OR UPDATE ON public.payment_term_template_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_template_fixed_needs_currency();

CREATE INDEX idx_ptt_lines_template ON public.payment_term_template_lines (template_id);

ALTER TABLE public.payment_term_template_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "payment_term_template_lines select by permission"
    ON public.payment_term_template_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));

CREATE POLICY "payment_term_template_lines insert by permission"
    ON public.payment_term_template_lines
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "payment_term_template_lines update by permission"
    ON public.payment_term_template_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit'::text)) WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "payment_term_template_lines delete by permission"
    ON public.payment_term_template_lines
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 payment_term_template_lines_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.payment_term_template_lines FROM authenticated, anon;
GRANT SELECT (id, template_id, seq, label, percentage, trigger_event, days_offset, notes, created_at)
    ON public.payment_term_template_lines TO authenticated;
