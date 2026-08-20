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
    -- EQP-1b-i:不再 NOT NULL —— 目的地二选一,由末尾那条 XOR CHECK 管
    inbound_batch_id  uuid REFERENCES public.inbound_batches (id),
    amount_base        numeric NOT NULL CHECK (amount_base > 0),
    notes             text,
    journal_entry_id  uuid REFERENCES public.journal_entries (id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    -- ── EQP-1b-i 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    expense_id        uuid REFERENCES public.expenses (id),
    currency          text REFERENCES public.currencies (code),
    amount_ccy        numeric,
    CONSTRAINT prepayment_applications_amount_ccy_positive
        CHECK (amount_ccy IS NULL OR amount_ccy > 0),
    CONSTRAINT prepayment_applications_one_destination
        CHECK (num_nonnulls(inbound_batch_id, expense_id) = 1)
);

-- EQP-1b-i:新行必须说出自己的币种,历史 NULL 原样不动 —— NOT VALID 只对 INSERT
-- 生效(FIN-32 给 inventory_ledger.business_date 立"新行必填"时的同一个形状)。
-- 【镜像里必须照写 NOT VALID】pg_constraint.convalidated 是目录里的一列,
-- 写成 VALID 会让判词二报漂移。
ALTER TABLE public.prepayment_applications
    ADD CONSTRAINT prepayment_applications_currency_stated
    CHECK (currency IS NOT NULL AND amount_ccy IS NOT NULL) NOT VALID;

CREATE INDEX idx_prepayment_applications_po ON public.prepayment_applications (purchase_order_id);
CREATE INDEX idx_prepayment_applications_inbound ON public.prepayment_applications (inbound_batch_id);
CREATE INDEX idx_prepayment_applications_expense ON public.prepayment_applications (expense_id);

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
GRANT SELECT (id, purchase_order_id, inbound_batch_id, expense_id, currency,
              notes, journal_entry_id, created_at, created_by)
    ON public.prepayment_applications TO authenticated;

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.prepayment_applications.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。
【EQP-1b-i 把它的口径写死在这里,因为两侧从此可能不相等】它是本次消耗掉的
【定金】那一侧的本位币值 = amount_ccy × 定金加权平均汇率(R1)或
= 被解除应付的本位币值(R2,价值对齐时两侧相等)。
【为什么取定金侧】可用预付的守卫(PREPAY_INSUFFICIENT)减的就是这一列,
它必须与 payment_allocations.allocated_base 在同一个计量口径上,否则每冲一次
就漂掉一次已实现汇兑。
【进料目的地上两侧恒等】R1(两边都是本位币,汇率皆 1)与 R2(按定义价值对齐)
都让定金侧 = 应付侧,所以 ap_open_items 的进料支一直以来直接减这一列是对的,
本刀没有改变那个读法。';

COMMENT ON COLUMN public.prepayment_applications.expense_id IS 'EQP-1b-i:第二个目的地 —— 这笔定金冲的是一张【费用单】的应付(设备采购的常态:
机器到货后开票,record_expense 以 unpaid 贷出 2000)。与 inbound_batch_id 恰一非空。
【为什么是费用单不是资产卡】应付是费用单贷出来的;一台机器可以经追加模式挂上
好几张费用单(运费、关税、安装),而定金冲的是某一张发票,不是一台机器。';

COMMENT ON COLUMN public.prepayment_applications.currency IS 'EQP-1b-i:本次冲抵【所陈述的币种】= 被解除的那笔应付的计价币种。
进料批次的应付恒以本位币计价(reprice_inbound_batch 按 base_currency_code() 过账),
费用单的应付以单据自己的币种计价(record_expense 按 p_currency 过账)。
历史 NULL:2026-07-31 那一行早于 FIN-0 本位币翻转,刻意未回填 —— 见
prepayment_applications_currency_stated 这条 NOT VALID 的 CHECK。';

COMMENT ON COLUMN public.prepayment_applications.amount_ccy IS 'EQP-1b-i:本次解除的应付金额,以 currency 计 —— 与 payment_allocations.allocated_ccy
同一个语义(敞口在单据币种空间恰好闭合)。费用支的敞口就是拿它来递减的。
【遮蔽】它与 amount_base 是同一笔钱的两种说法,所以不在列级 GRANT 里,
只经 prepayment_applications_masked 按 data.view_prices 读。';

COMMENT ON CONSTRAINT prepayment_applications_currency_stated ON public.prepayment_applications IS 'EQP-1b-i:每一条【新】冲抵都必须说出自己的币种与该币种下的金额。
NOT VALID —— 只对 INSERT 生效,不回头验既有行:线上那一行记于 2026-07-31,
早于 FIN-0(2026-08-04)的本位币翻转,是刻意留着的历史行。';

COMMENT ON CONSTRAINT prepayment_applications_one_destination ON public.prepayment_applications IS 'EQP-1b-i:一次冲抵恰好有一个目的地 —— 进料批次 或 费用单。放在【表上】,
所以直插也逃不掉;apply_prepayment 另有一条同义的按名拒绝
(PREPAY_DESTINATION_INVALID),因为屏幕上不该出现裸的约束违例。';
