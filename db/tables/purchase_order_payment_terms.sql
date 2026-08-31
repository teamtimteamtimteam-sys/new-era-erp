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
    -- EQP-PAY-1:那条 CHECK 退役,换成指向【字典】的外键。加宽 CHECK 只是把同一份
    -- 清单抄第三遍;外键之后,"有哪些里程碑"只有一个答案的所在地。
    trigger_event     text NOT NULL REFERENCES public.payment_trigger_events (code),
    due_date          date,
    CONSTRAINT po_payment_terms_fixed_date_needs_due CHECK (
        trigger_event <> 'fixed_date' OR due_date IS NOT NULL
    ),
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (purchase_order_id, seq),
    -- CASHFLOW-1（ALTER 加的列留在末尾，按镜像惯例）：这一期【预计】什么时候付。
    -- 它是一个估计，永远不写进 due_date —— due_date 在这张表上的含义是
    -- 「合同约定的日子」（下面那条 CHECK 要求 fixed_date 必须有它）。
    expected_date        date,
    expected_date_set_by uuid,
    expected_date_set_at timestamptz
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
-- CASHFLOW-1：列注释也要在镜像里 —— 一次重建缺了它，gate 的结构比对会红，
-- 而更要紧的是：下一个读镜像的人会少掉「为什么它不写进 due_date」这句话。
COMMENT ON COLUMN public.purchase_order_payment_terms.expected_date IS
    'CASHFLOW-1:这一期【预计】什么时候付 —— 一个估计,不是一个事实。★【为什么不写进 due_date】★ due_date 在这张表上的含义是"合同约定的日子"(表上那条 CHECK 要求 fixed_date 那一种必须有它);把估计写进去,会让一个猜测长得和一条合同条款一模一样。三种事件才需要它:on_shipment / on_arrival / post_assay —— 另外两种不需要,因为 fixed_date 已经有真日期,而 on_order 的日子是 purchase_orders.order_date 这个事实。谁设的、何时设的在旁边两列;按事件类型的保管人在 payment_event_owners。到了预测那一层它的 confidence 是 estimated,与 committed 【不同的渲染】。';

-- EQP-PAY-1(R5):这一期的里程碑,在这一类采购单上用得上吗。
-- 【两道闸的表那一道】门上那一道在 create_purchase_order 里 —— 一个禁用掉的下拉
-- 选项不是控制,而只写在函数里的校验挡不住直连 PostgREST。
-- 函数体在 db/functions/guard_payment_term_applicable.sql。
--
-- 【为什么 UPDATE 那一侧只挂在 trigger_event 上】线上 PO-2026-0007 第 3 期带着一个
-- 在设备单上用不上的 post_assay(见 docs/equipment-payment-milestones-and-retention.md,
-- 本刀【不改它】—— 那是一份真实单据的条款)。若把闸挂在整行 UPDATE 上,那一行就
-- 连别的列都改不动了:CASHFLOW-1 的 expected_date 恰好要落在 post_assay 这类期次上,
-- 于是给它填一个预计付款日会被拒 —— 一个与本刀无关的功能会因为一条历史数据坏掉。
CREATE TRIGGER trg_po_payment_terms_event_applicable
    BEFORE INSERT OR UPDATE OF trigger_event ON public.purchase_order_payment_terms
    FOR EACH ROW EXECUTE FUNCTION public.guard_payment_term_applicable();

REVOKE SELECT ON public.purchase_order_payment_terms FROM authenticated, anon;
-- CASHFLOW-1：三列新加的非敏感列一并授回 —— 列级 SELECT 授权【不会】自动
-- 延伸到后加的列，漏授的后果是「写得进、读不出」，连 WHERE 过滤都 42501。
GRANT SELECT (id, purchase_order_id, seq, label, percentage, trigger_event, due_date, notes, created_at,
              expected_date, expected_date_set_by, expected_date_set_at)
    ON public.purchase_order_payment_terms TO authenticated;
