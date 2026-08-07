-- db/tables/purchase_orders.sql
-- 采购订单:一张 PO = 一份【采购承诺】的存档(供应商、料、数量、估价、付款计划)。
--
-- 【PO 不过任何分录】—— 承诺不是交易。分录只在两个时刻产生:
--   * 钱动了 —— 预付(record_payment 核销到 purchase_order_id,借 1300 预付款项);
--   * 货到并计价了 —— 既有的 set_inbound_unit_price(借存货 / 贷 2000 应付)。
-- 所以本表没有 journal_entry_id,也没有任何触发器去记账。
--
-- estimated_total_ccy 是【估算】:等于各明细行 quantity × estimated_unit_price 之和,
-- 由 create_purchase_order 算好写死。公式定价的料常常下单时没有单价,那一行就记 0 ——
-- 权威金额永远是到货批次计价后的应付,不是这里。
--
-- approval_status:Tim 要的两级审批【结构在此,流程不在此】。列与取值先定下来,但本切
-- 没有审批流 —— 默认 'approved',create_purchase_order 直接盖上 approved_at/by。
-- 真正的送审/驳回留到权限切次,届时改的是流程而不是表结构。
--
-- 无缝编号 'PO-YYYY-NNNN':create_purchase_order 调 next_purchase_order_code(),
-- 咨询锁串行化取号(同 JE/收付款/开支/计价公式),回滚即释放号码。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.purchase_orders (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                   text NOT NULL UNIQUE,  -- gapless 'PO-YYYY-NNNN'
    supplier_id            uuid NOT NULL REFERENCES public.suppliers (id),
    order_date             date NOT NULL,
    expected_delivery_date date,
    currency               text NOT NULL DEFAULT 'USD' REFERENCES public.currencies (code),
    fx_rate                numeric NOT NULL DEFAULT 1 CHECK (fx_rate > 0),
    estimated_total_ccy    numeric NOT NULL DEFAULT 0,
    status                 text NOT NULL DEFAULT 'confirmed'
                           CHECK (status IN ('draft','confirmed','receiving','closed','cancelled')),
    approval_status        text NOT NULL DEFAULT 'approved'
                           CHECK (approval_status IN ('pending','approved','rejected')),
    approved_at            timestamptz,
    approved_by            uuid,
    incoterm               text,
    terms_text             text,
    notes                  text,
    closed_at              timestamptz,
    cancelled_at           timestamptz,
    cancel_reason          text,
    deleted_at             timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid DEFAULT auth.uid()
);

COMMENT ON COLUMN public.purchase_orders.estimated_total_ccy IS
    '估算总额,以【本单据自己的币种】(purchase_orders.currency)计 —— 不换算、不乘 fx_rate。FIN-28 前列名 estimated_total_usd,那个名字是错的:一张 SGD 的单存的就是 SGD。';

CREATE INDEX idx_purchase_orders_supplier ON public.purchase_orders (supplier_id);
CREATE INDEX idx_purchase_orders_order_date ON public.purchase_orders (order_date);

CREATE TRIGGER trg_purchase_orders_updated_at
    BEFORE UPDATE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_orders select by permission"
    ON public.purchase_orders
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));

CREATE POLICY "purchase_orders insert by permission"
    ON public.purchase_orders
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "purchase_orders update by permission"
    ON public.purchase_orders
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit'::text)) WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "purchase_orders delete by permission"
    ON public.purchase_orders
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 purchase_orders_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.purchase_orders FROM authenticated, anon;
GRANT SELECT (id, code, supplier_id, order_date, expected_delivery_date, currency, status, approval_status, approved_at, approved_by, incoterm, terms_text, notes, closed_at, cancelled_at, cancel_reason, deleted_at, created_at, created_by, updated_at, updated_by)
    ON public.purchase_orders TO authenticated;
