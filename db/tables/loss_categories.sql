-- db/tables/loss_categories.sql
-- PROC-BUILD-1:一笔损耗【是哪一种】。RUNTIME CONFIG,加一种是加一行。
--
-- 【为什么它必须存在】docs/proc-reality.md 第五部分 W2 判过:今天
-- processing_runs.loss_qty 把【三件物理上不同的事】塌成一个数,而 (i) 与 (ii)
-- 对「金属去哪了」的答案【相反】—— 所以回收率永远算不对。
--
-- NOTE: introduced by db/migrations/2026-08-30-procbuild1-loss-categories-forms-and-saleability.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.loss_categories (
    code         text PRIMARY KEY,
    name_en      text NOT NULL,
    name_zh      text NOT NULL,
    -- 【规则列 ①】金属跟着走了没有。**这是这张字典存在的全部理由。**
    metal_fate   text NOT NULL REFERENCES public.loss_metal_fates (code),
    -- 【规则列 ②】这是不是【真的损耗】。residue_disposal 为 false ——
    -- 它是一条带负价值的产出,暂时停在这里,不是它的归宿。
    is_true_loss boolean NOT NULL,
    is_active    boolean NOT NULL DEFAULT true,
    sort_order   integer NOT NULL DEFAULT 0,
    notes        text
);

COMMENT ON TABLE public.loss_categories IS
'PROC-BUILD-1:一笔损耗【是哪一种】。RUNTIME CONFIG,加一种是加一行。

【为什么它必须存在】docs/proc-reality.md 第五部分 W2 判过:今天
`processing_runs.loss_qty` 是一个 numeric,而它把【三件物理上不同的事】塌成一个数:
  (i) 水与挥发物 —— 质量走了、**金属留着**;
  (ii) 粉尘与洒漏 —— 都走了,这是唯一被表示对的一种;
  (iii) 残渣送处置 —— **根本不是损耗**,是一条带负价值的产出。
(i) 与 (ii) 对「金属去哪了」的答案【相反】,所以合在一个数里,
**回收率永远算不对,而错的方向取决于当天湿度**。

【这是本刀选中它的理由】七件事里其余六件今天是【沉默】(说不出口);
只有这一件今天在【发声而且说错】。沉默不会传染,错数会 ——
proc-reality 的 F4 数过它已经污染了四个互相印证的数字。';

COMMENT ON COLUMN public.loss_categories.metal_fate IS
'PROC-BUILD-1:这一种损耗把【金属】带走了没有。**一个数答不了这个问题,
这一列就是把那个问题分开的地方。** 回收率将来要按它分支:
金属留着的那部分不该被扣分,金属走了的那部分该。';

COMMENT ON COLUMN public.loss_categories.is_true_loss IS
'PROC-BUILD-1:这是不是【真的损耗】。**false 的那些是停在这里的过路客。**
W2-(iii) 判过:送去处置的残渣有重量、有去向、有一张处置费单据,而且有
Basel/牌照意义上的申报义务 —— **把它记成"损耗"等于让它从物料台账上消失,
而监管问的正是它**。它的归宿是一条【带负价值的产出】,那要等 U6(哪几条产出流
存在)。**在 U6 答之前,记成一个具名的类别【好过】记成 loss_qty 里一个匿名的数**,
而这一列让"它还没到家"留在数据里,不留在散文里。';

INSERT INTO public.loss_categories (code, name_en, name_zh, metal_fate, is_true_loss, sort_order, notes) VALUES
    ('moisture',
     'Water & volatiles', '水与挥发物', 'stays', true, 1,
     'W2-(i)。【Tim 已裁定】蒸发掉的水【本身就是一种损耗】,而且是"质量走了、金属没走"的那一种 —— 所以 is_true_loss 为真而 metal_fate 为 stays,两者不矛盾。'),
    ('dust_spill',
     'Dust & spillage', '粉尘与洒漏', 'leaves', true, 2,
     'W2-(ii)。**这是今天唯一被 loss_qty 表示对的一种** —— 质量与金属一起走。'),
    ('residue_disposal',
     'Residue sent for disposal', '残渣送处置', 'leaves', false, 3,
     'W2-(iii)。**它根本不是损耗** —— is_true_loss 为 false 就是这句话。它有重量、有去向、有一张处置费单据,归宿是一条带负价值的产出(U6)。在那之前记成一个具名类别,好过记成 loss_qty 里一个匿名的数。'),
    ('electrolyte_evaporation',
     'Electrolyte evaporation', '电解液挥发', 'unknown', true, 4,
     '【R4,Tim 的工艺路线】电解液目前计划挥发掉 —— 它既不是产品也不是废物收据,是【消失掉的质量】。**它没有并进 moisture,理由是 metal_fate**:moisture 那一行断言"金属留着",而电解液带不带走金属【今天没有人知道】(线上产出批化验 0 条)。并进去等于免费送出一个未经证实的断言,而那个断言会直接流进回收率 —— 那正是 W2/F4 记过账的那一种污染。');

ALTER TABLE public.loss_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "loss_categories select all" ON public.loss_categories
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "loss_categories insert by permission" ON public.loss_categories
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.processing.edit'::text));
CREATE POLICY "loss_categories update by permission" ON public.loss_categories
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.loss_categories TO authenticated;
