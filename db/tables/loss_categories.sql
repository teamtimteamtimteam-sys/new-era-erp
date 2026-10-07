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
    notes        text,
    -- ── MES-4b 追加的列(2026-10-07,MES-0 Q51;MES-4b Step 0 Q16 · Q18)──────────────────────────────
    -- 【规则列 ③】这一类能不能是【算出来的】(processing_run_losses.basis = 'derived')。引导只有 electrolyte_evaporation 为真。
    may_be_derived boolean NOT NULL DEFAULT false
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
     '【MES-4b,Tim 的工厂事实(Step 0 Q17)】挥发出来的电解液由抽风气流带走,经风管送到后端的环保(尾气处理)设备处理 —— 设备里一台压缩机让气体单向流动;压缩机是设备,不是工序,不挂在加工单上。它仍然是这一段的一笔【有名字的损耗】。哪几段挥发由工序上的「Electrolyte evaporates in this step」勾选说(Tim 自己勾);那一段给了电解液份额(V10)之后,这一笔可以按份额算出来(basis = derived),也可以量出来。
【R4,Tim 的工艺路线】电解液目前计划挥发掉 —— 它既不是产品也不是废物收据,是【消失掉的质量】。**它没有并进 moisture,理由是 metal_fate**:moisture 那一行断言"金属留着",而电解液带不带走金属【今天没有人知道】(线上产出批化验 0 条)。并进去等于免费送出一个未经证实的断言,而那个断言会直接流进回收率 —— 那正是 W2/F4 记过账的那一种污染。'),
    -- ── MES-4a(2026-10-07,MES-0 Q56 · 规格 §4.1;MES-4a Step 0 Q2,Tim:三类提前到本刀)──────────────────
    -- 规格 §4.1 点名的可审计类别:取样消耗、留在设备里的料、回收的扫地料。仍然没有 other(规格:一笔叫"其它"的损耗没有审计价值)。
    ('sampling_consumption',
     'Sampling consumption', '取样消耗', 'leaves', true, 5,
     '【MES-4a · 规格 §4.1】取样拿去化验、不回来的那部分 —— 质量与金属一起离开这一炉(去了化验室)。'),
    ('equipment_holdup',
     'Material held up in equipment', '留在设备里的料', 'stays', false, 6,
     '【MES-4a · 规格 §4.1 · R7】一炉跑完留在机器里、被下一炉带走的料(heel)。Tim 的 R7:heel 是存货 —— 它没有离开工厂,所以 is_true_loss 为 false、金属留着。'),
    ('sweepings',
     'Sweepings recovered', '回收的扫地料', 'stays', false, 7,
     '【MES-4a · 规格 §4.1】扫起来、收回来的料 —— 它没有丢,只是还没回到一条有名字的产出里,所以 is_true_loss 为 false、金属留着。');

-- MES-4b(Step 0 Q18):只有电解液挥发可以是算出来的(份额 × 投入)—— 其余每一类只能量出来。
UPDATE public.loss_categories SET may_be_derived = true WHERE code = 'electrolyte_evaporation';

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

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.loss_categories
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');

COMMENT ON COLUMN public.loss_categories.may_be_derived IS
'MES-4b(MES-0 Q51;MES-4b Step 0 Q18):这一类损耗能不能是【算出来的】(processing_run_losses.basis = derived)。引导只有 electrolyte_evaporation 为真 ——
record_derived_electrolyte_loss 只认它。算出来的永远是 份额 × 投入,从来不是余数。';
