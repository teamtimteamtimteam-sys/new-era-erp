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
    -- 【没有默认值,这是有意的 —— FIN-35】汇率的默认值只能是一个假设,而假设出来的
    -- 1:1 在非本位币单据上永远是错的、还看起来完全正常(就是 FX 规则清掉的那个 `?? 1`)。
    -- create_purchase_order 按 order_date 的 tt_sell 取,缺牌价即 FX_RATE_MISSING 点名拒绝;
    -- NOT NULL 是兜底 —— 漏传就撞它,而不是拿到一个编出来的 1。
    fx_rate                numeric NOT NULL CHECK (fx_rate > 0),
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
    updated_by             uuid DEFAULT auth.uid(),
    -- ── AUDEL-1b 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────
    deleted_by    uuid,
    delete_reason text,
    cancelled_by  uuid
);

COMMENT ON COLUMN public.purchase_orders.fx_rate IS
    '本单据成立时的折本位币汇率(create_purchase_order 按 order_date 的 tt_sell 取,缺牌价即拒)。【没有默认值,这是有意的 —— FIN-35】:汇率的默认值只能是一个假设,而假设出来的 1:1 在非本位币单据上永远是错的,还看起来完全正常。NOT NULL 是兜底,带名字的拒绝在 fx_rate_for。';

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
GRANT SELECT (id, code, supplier_id, order_date, expected_delivery_date, currency, status, approval_status, approved_at, approved_by, incoterm, terms_text, notes, closed_at, cancelled_at, cancel_reason, deleted_at, created_at, created_by, updated_at, updated_by, deleted_by, delete_reason, cancelled_by)
    ON public.purchase_orders TO authenticated;

-- APR-2 决定 4:金额被改到需要更高一级审批时,原审批作废并重新路由。
-- 【今天没有任何真实路径能触发它】—— 采购单与明细没有修改入口(见
-- docs/approvals-scoping.md 的 A 部分)。规则挂在金额本身上,等修改功能建出来时
-- 它已经在那儿了。函数体在 db/functions/void_approval_on_amount_increase.sql。
CREATE TRIGGER trg_purchase_orders_void_approval
    BEFORE UPDATE OF estimated_total_ccy, fx_rate ON public.purchase_orders
    FOR EACH ROW
    WHEN (NEW.estimated_total_ccy IS DISTINCT FROM OLD.estimated_total_ccy
          OR NEW.fx_rate IS DISTINCT FROM OLD.fx_rate)
    EXECUTE FUNCTION public.void_approval_on_amount_increase();

-- ── PUR-2:修改守卫与留痕 ────────────────────────────────────────────────────
-- 【调查结论:商业字段从来只是够不着,不是被保护】本表此前只有 updated_at 与
-- APR-2 的作废触发器,而 RLS 允许任何持 module.purchasing.edit 的人直接 UPDATE。
-- 所以守卫必须是【触发器】,不能只写在写入函数里 —— 否则那条直连的路照样通。
-- 函数体见 db/functions/guard_po_amendable.sql 与 trg_po_history_header.sql。
CREATE TRIGGER guard_purchase_orders_amendable
    BEFORE UPDATE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_amendable();

CREATE TRIGGER trg_purchase_orders_history
    AFTER UPDATE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION public.trg_po_history_header();

-- AUDEL-1a:硬删按名拒(PO_NO_HARD_DELETE|单号)。此前拦住【带明细】采购单的是一次
-- 顺带:CASCADE 删明细时触发写历史,那条历史行的外键指回已删的单,于是失败 ——
-- 报出来的是 "insert or update on table purchase_order_history violates foreign key
-- constraint ...",既没说是哪张单也没说规矩;而【零明细】的单它完全不拦(实测删得掉)。
CREATE TRIGGER trg_purchase_orders_no_hard_delete
    BEFORE DELETE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_purchase_order_no_hard_delete();

-- AUDEL-1b:置 deleted_at 必须走【门】(函数),且 deleted_by / delete_reason 必须填好。
-- 光加两列挡不住任何事 —— 软删本来就是一次直连 UPDATE。
CREATE TRIGGER trg_purchase_orders_soft_delete_provenance
    BEFORE UPDATE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();
