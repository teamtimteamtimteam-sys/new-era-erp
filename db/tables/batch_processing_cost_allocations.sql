-- db/tables/batch_processing_cost_allocations.sql
-- PROC-COST-1:加工成本【资本化进批次】的载体 —— 第二个成本组件,不是更高的单价。
--
-- NOTE: introduced by
--   db/migrations/2026-08-31-proccost1-processing-cost-capitalises-onto-the-input-batch.sql
-- This mirror is a first-run script (plain CREATEs). Re-running requires dropping
-- the objects first. Run in the Supabase SQL Editor.
--
-- 【形状来自 FRT-1 的 freight_allocations,那是刻意的】一张对批次记成本事件的台账
-- + 一个求和的派生函数(batch_processing_cost_base),不是批次上的一列。
-- 累加(SUM)与冲销即解除(只认活着且已提交的加工单)都由这个形状【免费提供】;
-- 一列两样都做不到 —— 它得读-改-写,而一批货被放电两次会互相覆盖。
--
-- 【它与 unit_price 的分界,也是上一刀停下来的理由】unit_price 是【应付之锚】:
-- ap_open_items 按 quantity × unit_price 实时算欠供应商多少钱。把我们自己烧的电
-- 并进去 = 凭空捏造供应商债务。所以成本另起一张台账,估值读
--     quantity × unit_price + batch_freight_base + batch_processing_cost_base。
--
-- 【为什么不并进 freight_allocations】运费单指名一个【货代】,是我们欠钱的对手方,
-- 未付即成为 ap_open_items 的一行;我们自己烧的电不欠任何人。把一个非应付项塞进
-- 一个整体形状都假设有对手方的结构里,迟早有人会按那个假设去读它。

CREATE TABLE public.batch_processing_cost_allocations (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 【成本事件的来源】加工单。冲销即解除靠它:基函数只认活着且已提交的单。
    run_id           uuid NOT NULL REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    -- 【收件人】进料批。产出批不在这个地址空间里 —— 见迁移 2e 的第 2 条拒绝。
    inbound_batch_id uuid NOT NULL REFERENCES public.inbound_batches (id),
    -- 【刻意【没有】>= 0 的约束,而 freight_allocations 有】运费永远为正(总是欠货代
    -- 一笔钱),而 processing_cost_entries 明写"Deliberately no sign check:
    -- by-product / disposal offsets may be negative"。照抄那条约束会让一笔副产品
    -- 冲抵在这里撞墙,而它在源表里是合法的。**形状照抄,理由不成立的约束不照抄。**
    amount_base      numeric NOT NULL,
    -- 【可审计与"碰巧算对了"的分界】这一份是从什么数算出来的:该批的投料量,
    -- 以及全单的投料总量。分摊要能被重新导出,不是被相信(与 freight_allocations
    -- 的 basis_qty 同一条论证)。
    basis_qty        numeric NOT NULL,
    basis_total_qty  numeric NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    -- 一张单对一批货只出一行;重分摊先删后插,所以这条约束也是幂等性的保证。
    UNIQUE (run_id, inbound_batch_id)
);

COMMENT ON TABLE public.batch_processing_cost_allocations IS
'PROC-COST-1:加工成本【资本化进批次】的载体 —— 第二个成本组件,不是更高的单价。

【它与 unit_price 的关系,一句话说清】unit_price 是【应付之锚】(ap_open_items 按
quantity × unit_price 算欠供应商多少钱)。把我们自己烧的电并进去 = 凭空捏造供应商债务。
所以成本【另起一张台账】,估值读"采购价 + batch_freight_base + batch_processing_cost_base"。

【形状来自 FRT-1,那是刻意的】一张对批次记成本事件的台账 + 一个求和的派生函数,
不是批次上的一列。累加(SUM)与冲销即解除(只认活着且已提交的加工单)都由形状免费提供。
一列做不到这两样:它得读-改-写,而两次放电会互相覆盖。

【为什么不并进 freight_allocations】运费单指名一个【货代】,是我们欠钱的对手方,
未付即成为 ap_open_items 的一行。我们自己烧的电不欠任何人。';

COMMENT ON COLUMN public.batch_processing_cost_allocations.amount_base IS
    'PROC-COST-1:本位币金额。【刻意没有 >= 0 约束】—— 源表 processing_cost_entries 明写允许负数(副产品/处置冲抵),照抄 freight_allocations 的正数约束会让一笔在源表里合法的冲抵在这里撞墙。';
COMMENT ON COLUMN public.batch_processing_cost_allocations.basis_qty IS
    'PROC-COST-1:这一份是【从什么数算出来的】—— 该批在本单的投料量(basis_total_qty 是全单投料总量)。分摊要能被重新导出,不是被相信(与 freight_allocations.basis_qty、FIN-26 的 price_source、METAL-3 的 fx_legs 同源)。';
COMMENT ON COLUMN public.batch_processing_cost_allocations.run_id IS
    'PROC-COST-1:成本事件的来源加工单。【冲销即解除靠这一列】batch_processing_cost_base 只认 deleted_at IS NULL AND status = ''committed'' 的单 —— 回滚把单软删,这一行就自动不计,与 batch_freight_base 只认 status=''posted'' 的运费单同构。';

ALTER TABLE public.batch_processing_cost_allocations ENABLE ROW LEVEL SECURITY;
-- 读:进料侧与财务侧都要看得见(批次页的落地成本拆解在进料侧)。与 freight_allocations 同形。
CREATE POLICY "batch_processing_cost_allocations select by permission"
    ON public.batch_processing_cost_allocations AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view') OR has_permission('module.finance.view')
           OR has_permission('module.processing.view'));
-- 写:只由 allocate_processing_costs(SECURITY DEFINER)产生。这条策略是给人挡的门,
-- 不是给函数开的门 —— 函数以属主身份跑,绕过 RLS。
CREATE POLICY "batch_processing_cost_allocations write by permission"
    ON public.batch_processing_cost_allocations AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'))
    WITH CHECK (has_permission('module.processing.edit'));

CREATE INDEX idx_bpca_batch ON public.batch_processing_cost_allocations (inbound_batch_id);
CREATE INDEX idx_bpca_run   ON public.batch_processing_cost_allocations (run_id);

-- PROC-COST-1 fu1:【一行载体必须指向它自己那张单的投料批】。走
-- allocate_processing_costs 天然成立;这道闸挡的是【直接 INSERT】那条路 ——
-- 这张表对 authenticated 可写(与 freight_allocations 同形),所以"走那条路不会挂错"
-- 与"不可能挂错"是两件事,而 2b 要的是后者。挂错的后果是成本跟着别的货走进
-- 别人的产出单位成本里,而每一张分录仍然是平的。
-- 跨两张表的规矩,CHECK 看不见 —— 函数体在 db/functions/guard_bpca_batch_is_input.sql。
CREATE TRIGGER trg_bpca_batch_is_input
    BEFORE INSERT OR UPDATE ON public.batch_processing_cost_allocations
    FOR EACH ROW EXECUTE FUNCTION public.guard_bpca_batch_is_input();
