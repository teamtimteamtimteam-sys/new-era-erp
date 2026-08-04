-- db/tables/prepayment_applications.sql
-- 预付冲抵台账:一行 = 把某张 PO 上的一笔预付,挪到某张【已收货、已计价】的到货批次
-- 的应付上。由 apply_prepayment() 唯一写入。
--
-- 会计含义:钱在付定金那一刻就已经离开银行(那时借的是 1300 预付款项)。这里【不动
-- 现金】,只是科目之间的搬运 —— 借 2000 应付账款 / 贷 1300 预付款项。
--
-- IMMUTABLE:INSERT+SELECT RLS + 守卫触发器(UPDATE/DELETE 一律 RAISE)。冲抵错了
-- 不靠改行,靠反向业务动作 —— 与 payments / payment_allocations / journal_entries
-- 同一套不可变原则。
--
-- 两个方向的余额都从本表推导:
--   * PO 的可用预付 = Σ(指向该 PO 的 posted 收付款核销) − Σ(本表该 PO 的冲抵额);
--   * 批次的已结额 = Σ(指向该批次的 posted 收付款核销) + Σ(本表该批次的冲抵额),
--     ap_open_items 的进料侧就是这么算的 —— 少了后一项,被定金付清的批次会永远显示未付。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.prepayment_applications (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id uuid NOT NULL REFERENCES public.purchase_orders (id),
    inbound_batch_id  uuid NOT NULL REFERENCES public.inbound_batches (id),
    amount_base        numeric NOT NULL CHECK (amount_base > 0),
    notes             text,
    journal_entry_id  uuid REFERENCES public.journal_entries (id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid()
);

CREATE INDEX idx_prepayment_applications_po ON public.prepayment_applications (purchase_order_id);
CREATE INDEX idx_prepayment_applications_inbound ON public.prepayment_applications (inbound_batch_id);

CREATE OR REPLACE FUNCTION public.reject_prepayment_application_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'PREPAYMENT_APPLICATION_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_prepayment_applications_immutable
    BEFORE UPDATE OR DELETE ON public.prepayment_applications
    FOR EACH ROW EXECUTE FUNCTION public.reject_prepayment_application_mutation();

ALTER TABLE public.prepayment_applications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "prepayment_applications select by permission"
    ON public.prepayment_applications
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "prepayment_applications insert by permission"
    ON public.prepayment_applications
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 prepayment_applications_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.prepayment_applications FROM authenticated, anon;
GRANT SELECT (id, purchase_order_id, inbound_batch_id, notes, journal_entry_id, created_at, created_by)
    ON public.prepayment_applications TO authenticated;

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.prepayment_applications.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';
