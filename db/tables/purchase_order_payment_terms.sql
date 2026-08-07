-- db/tables/purchase_order_payment_terms.sql
-- 一张采购订单的付款计划:一行一期。
--
-- 【计划逐合同而定】。期数、比例、触发事件都随交易对手和合同变化 —— 系统里【任何
-- 地方都没有】80/10/10 或别的默认拆法,每张 PO 自带它自己的计划。这张表的形状就是
-- 为了容纳"合同上写的那样":任意期数、按比例或按定额、两者可以在同一张计划里混用。
--
-- percentage 与 fixed_amount_ccy 【二选一】(num_nonnulls = 1)。
-- percentage 是对该 PO 的 estimated_total_ccy 而言。
--
-- 【计划不是债权】:一旦实际化验落地,这张计划就只是【指引】—— 权威的欠款金额永远
-- 是"已计价到货批次的应付"(ap_open_items)。所以本表不参与任何结算或分录计算,
-- 也没有"已付/未付"状态列;它是排期的依据,不是账。
--
-- trigger_event 'fixed_date' 必须给 due_date(CHECK 强制);其余事件的 due_date 可空
-- —— 到货日、化验完成日这类时点在下单时还不知道。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.purchase_order_payment_terms (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id uuid NOT NULL REFERENCES public.purchase_orders (id) ON DELETE CASCADE,
    seq               integer NOT NULL,
    label             text NOT NULL,
    percentage        numeric CHECK (percentage IS NULL OR (percentage > 0 AND percentage <= 100)),
    fixed_amount_ccy  numeric CHECK (fixed_amount_ccy IS NULL OR fixed_amount_ccy > 0),
    CONSTRAINT po_payment_terms_pct_xor_fixed CHECK (num_nonnulls(percentage, fixed_amount_ccy) = 1),
    trigger_event     text NOT NULL
                      CHECK (trigger_event IN ('on_order','on_shipment','on_arrival','post_assay','fixed_date')),
    due_date          date,
    CONSTRAINT po_payment_terms_fixed_date_needs_due CHECK (
        trigger_event <> 'fixed_date' OR due_date IS NOT NULL
    ),
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (purchase_order_id, seq)
);

COMMENT ON COLUMN public.purchase_order_payment_terms.fixed_amount_ccy IS
    '该期的定额,以【所属单据自己的币种】计(与同表 percentage 所依据的 estimated_total_ccy 同币)。FIN-28 前列名 fixed_amount_usd。';

CREATE INDEX idx_po_payment_terms_po ON public.purchase_order_payment_terms (purchase_order_id);

ALTER TABLE public.purchase_order_payment_terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_order_payment_terms select by permission"
    ON public.purchase_order_payment_terms
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));

CREATE POLICY "purchase_order_payment_terms insert by permission"
    ON public.purchase_order_payment_terms
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "purchase_order_payment_terms update by permission"
    ON public.purchase_order_payment_terms
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit'::text)) WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "purchase_order_payment_terms delete by permission"
    ON public.purchase_order_payment_terms
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 purchase_order_payment_terms_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.purchase_order_payment_terms FROM authenticated, anon;
GRANT SELECT (id, purchase_order_id, seq, label, percentage, trigger_event, due_date, notes, created_at)
    ON public.purchase_order_payment_terms TO authenticated;
