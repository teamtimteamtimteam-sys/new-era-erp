-- db/tables/processing_run_losses.sql
-- PROC-BUILD-1:一张加工单上【分了类的那部分损耗】,一类一条。
-- ★ MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q17 · Q28,Tim):【只追加】。
--   此前页面直连 upsert / 硬删(一行"真的没了")—— 规格说加工记录写了就不改。现在:
--   · 一条有名字的损耗 = 一行原始记录(corrects_id 为空),一张单的同一类只能有一条原始记录(processing_run_losses_one_original);
--   · 改它 = 一条新行指回它(corrects_id 唯一 —— 一行只被更正一次,读链的末端)+ 必填理由;撤回 = 更正成 0;
--   · 只经 record_run_loss / correct_run_loss(module.processing.edit 或 action.processing_aftercare,与此前同一组码)写 ——
--     authenticated 只剩 SELECT;UPDATE / DELETE / TRUNCATE 语句级拒(APPEND_ONLY)。
--   · 主键从 (run_id, loss_category_code) 换成 id(identity —— 也是结平水位线读的那个序号);变更记录的绑定键跟着换。
-- 【与 loss_qty 的关系】MES-4a 起新单的 loss_qty = 投入 − 产出(推出来的,不再收一个敲进来的不同的数 —— Q17);
--   有名字的损耗(每一类【当前】那一条之和)不许超过它 —— LOSS_CATEGORIES_EXCEED_LOSS_QTY。剩下的就是【没解释的余数】,由结平说出来。
--
-- NOTE: introduced by db/migrations/2026-08-30-procbuild1-loss-categories-forms-and-saleability.sql;
--       reshaped append-only by db/migrations/2026-10-07-mes4a-processing-record.sql (ALTER-added columns at the end).
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_run_losses (
    run_id             uuid NOT NULL REFERENCES public.processing_runs (id) ON DELETE CASCADE,
    loss_category_code text NOT NULL REFERENCES public.loss_categories (code),
    quantity           numeric NOT NULL,
    notes              text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid DEFAULT auth.uid(),
    -- ── MES-4a 追加的列 ──────────────────────────────────────────────────────
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    corrects_id        bigint UNIQUE REFERENCES public.processing_run_losses (id),
    correction_reason  text,
    -- ── MES-4b 追加的列(2026-10-07,规格 §3.4;MES-0 Q51;MES-4b Step 0 Q16 · Q18 · Q19,Tim)─────────────
    -- 这一条是【量出来的】(measured:敲进来的公斤数 —— record_run_loss / correct_run_loss)还是【算出来的】
    -- (derived:电解液份额 × 这一炉的投入 —— record_derived_electrolyte_loss / rederive_electrolyte_loss)。必填,没有默认值:
    -- 每一扇写它的门都明说自己是哪一种。MES-4b 之前的行(线上 0 行)在迁移里记成 measured。
    basis              text NOT NULL CHECK (basis IN ('measured', 'derived')),
    -- 算出来的那一条用的是【当时】哪一个份额(operation_types.electrolyte_share_pct,V10)—— 抄下来,改份额不重写旧行。
    derived_share_pct  numeric,
    CONSTRAINT processing_run_losses_basis_shape
        CHECK ((basis = 'derived') = (derived_share_pct IS NOT NULL)),
    -- 原始记录必须为正(一条为零的损耗与"没有这一类"分不开);更正可以是 0 —— 那就是撤回
    CONSTRAINT processing_run_losses_quantity_shape
        CHECK (quantity > 0 OR (quantity = 0 AND corrects_id IS NOT NULL)),
    CONSTRAINT processing_run_losses_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> ''))
);

-- 【一张单的同一个类别只有一条原始记录】(PROC-BUILD-1 那条规矩,原来由复合主键执行):重复一条不是"更确定",
-- 它只会让任何按类别求和的读法开始骗人。之后的改动是更正链,不是第二条原始记录。
CREATE UNIQUE INDEX processing_run_losses_one_original ON public.processing_run_losses (run_id, loss_category_code)
    WHERE corrects_id IS NULL;

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
'PROC-BUILD-1:这一类损耗的量,单位与加工单一致。原始记录**必须为正** ——
一笔为零的损耗与"没有这一类"分不开,而后者由"没有这一行"表示。
MES-4a:更正行可以是 0 —— 那就是撤回这一类(链的末端是 0,当前之和不算它)。';

ALTER TABLE public.processing_run_losses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_losses select by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
-- ★ MES-4a(2026-10-07,Q28 · Q32):INSERT / UPDATE / DELETE 三条写策略拿掉 —— 只经 record_run_loss / correct_run_loss(SECURITY DEFINER,
--   module.processing.edit 或 action.processing_aftercare,与此前那三条策略同一组码)写。authenticated 只剩 SELECT,所以直连写
--   在权限那一步就是 42501(不是零行、不是"成功的空操作")。

-- 有名字的损耗(每一类当前那一条之和)不许超过 loss_qty。只追加之后只剩 INSERT 会动它。
CREATE CONSTRAINT TRIGGER trg_processing_run_losses_within_total
    AFTER INSERT ON public.processing_run_losses
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_run_losses();

-- 只追加:UPDATE / DELETE / TRUNCATE 一律语句级拒 —— 连属主路径也不改它(更正是新行)。
CREATE TRIGGER trg_processing_run_losses_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_losses
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

REVOKE ALL ON public.processing_run_losses FROM authenticated, anon;
GRANT SELECT ON public.processing_run_losses TO authenticated;

COMMENT ON COLUMN public.processing_run_losses.basis IS
'MES-4b(规格 §3.4 "marked measured or derived";MES-0 Q51;MES-4b Step 0 Q16):measured = 量出来的(敲进来的公斤数);derived = 算出来的
(电解液份额 V10 × 这一炉的投入 / 100,derived_share_pct 记下用的份额)。**derived 永远不是余数**(投入 − 产出 − 别的损耗)——
那会让每一炉按构造结平(AGENTS.md 的兜底桶)。只有 loss_categories.may_be_derived 为真的类别(electrolyte_evaporation)能是 derived。
更正可以重新算(rederive_electrolyte_loss)或改成量出来的(correct_run_loss),都要理由;结平的算术不分 basis(平衡面板单独报出算出来的那一截)。';
