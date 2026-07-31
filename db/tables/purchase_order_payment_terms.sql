-- db/tables/purchase_order_payment_terms.sql
-- 一张采购订单的付款计划:一行一期。
--
-- 【计划逐合同而定】。期数、比例、触发事件都随交易对手和合同变化 —— 系统里【任何
-- 地方都没有】80/10/10 或别的默认拆法,每张 PO 自带它自己的计划。这张表的形状就是
-- 为了容纳"合同上写的那样":任意期数、按比例或按定额、两者可以在同一张计划里混用。
--
-- percentage 与 fixed_amount_usd 【二选一】(num_nonnulls = 1)。
-- percentage 是对该 PO 的 estimated_total_usd 而言。
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
    fixed_amount_usd  numeric CHECK (fixed_amount_usd IS NULL OR fixed_amount_usd > 0),
    CONSTRAINT po_payment_terms_pct_xor_fixed CHECK (num_nonnulls(percentage, fixed_amount_usd) = 1),
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

CREATE INDEX idx_po_payment_terms_po ON public.purchase_order_payment_terms (purchase_order_id);

ALTER TABLE public.purchase_order_payment_terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on purchase_order_payment_terms"
    ON public.purchase_order_payment_terms AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
