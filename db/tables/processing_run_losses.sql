-- db/tables/processing_run_losses.sql
-- PROC-BUILD-1:一张加工单上【分了类的那部分损耗】,一类一行。
-- **processing_runs.loss_qty 本刀一列都没动** —— 两者不必相等,但分类之和不许超过它。
-- 【它答不了"过磅误差不是损耗"】—— 见表注,那是一条记在案的遗留缺口。
--
-- NOTE: introduced by db/migrations/2026-08-30-procbuild1-loss-categories-forms-and-saleability.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_run_losses (
    run_id             uuid NOT NULL REFERENCES public.processing_runs (id) ON DELETE CASCADE,
    loss_category_code text NOT NULL REFERENCES public.loss_categories (code),
    quantity           numeric NOT NULL CHECK (quantity > 0),
    notes              text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid DEFAULT auth.uid(),
    -- 【一张单的同一个类别只记一行】与 inbound_batch_safety_states 同一条:
    -- 重复一行不是"更确定",它只会让任何按类别求和的读法开始骗人。
    PRIMARY KEY (run_id, loss_category_code)
);

COMMENT ON TABLE public.processing_run_losses IS
'PROC-BUILD-1:一张加工单上【分了类的那部分损耗】,一类一行。

【它与 processing_runs.loss_qty 的关系 —— 本刀【不动】那一列】
  * **它们不必相等,而且现在【刻意】不要求相等。** 产线还没开,没有人知道
    三类各占多少;要求相等等于逼操作员编一个数去凑平,而编出来的数
    与量出来的数在报表里长得一模一样。
  * **但分类之和【不许超过】 loss_qty** —— 这条守得住,因为它不需要知道真实配比。
    它与 commit_processing_run 的 OUTPUT_EXCEEDS_INPUT 是同一个形状:
    一条【不等式】可以在真值未知时断言,一条【等式】不行。
    违反时按名拒:LOSS_CATEGORIES_EXCEED_LOSS_QTY。
  * 差额(loss_qty − 已分类之和)= **还没有解释的质量**,由
    processing_run_loss_breakdown 说出来。

【★ 它【不能】回答的那个问题,写在这里免得被当成已解决 ★】
**"过磅误差不是损耗"** —— 这张表把质量分成【已解释】与【未解释】两部分,
但【未解释】里混着两件事:还没有人去分类的损耗,与账本身对不上。
**要分开这两件,需要有人【断言】"这批数字对不上",而那个断言今天没有地方放。**
本刀【刻意不建】一个叫"过磅误差"的损耗类别 —— 那会把一个记账问题
伪装成一件物理事实,而这正是 loss_qty 今天在犯的错的小号版本。
记为遗留缺口,归属:称重与对账那一刀。';

COMMENT ON COLUMN public.processing_run_losses.quantity IS
'PROC-BUILD-1:这一类损耗的量,单位与加工单一致。**必须为正** ——
一笔为零的损耗与"没有这一类"分不开,而后者由"没有这一行"表示。';

ALTER TABLE public.processing_run_losses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_losses select by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
CREATE POLICY "processing_run_losses insert by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));
CREATE POLICY "processing_run_losses update by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
CREATE POLICY "processing_run_losses delete by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'::text));

CREATE CONSTRAINT TRIGGER trg_processing_run_losses_within_total
    AFTER INSERT OR UPDATE OR DELETE ON public.processing_run_losses
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_run_losses();

GRANT SELECT, INSERT, UPDATE, DELETE ON public.processing_run_losses TO authenticated;
