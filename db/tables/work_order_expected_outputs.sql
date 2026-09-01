-- db/tables/work_order_expected_outputs.sql
-- WO-1a:预期产出(可选)—— 这里的数是排计划那个人的【估计】,不是一条标准;没有行 = 没人估过,不是估了零。
--
-- NOTE: introduced by db/migrations/2026-08-16-wo1a-work-order-document.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.work_order_expected_outputs (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    work_order_id uuid NOT NULL REFERENCES public.work_orders (id) ON DELETE RESTRICT,
    material_id   uuid NOT NULL REFERENCES public.materials (id),
    expected_qty  numeric NOT NULL CHECK (expected_qty > 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    -- ── PROC-SUPPORT-1(R3)追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──
    -- 这个预期产出【是怎么来的】,以及它的凭据。**不覆盖 expected_qty** ——
    -- 那正是本表表注早就规定好的形状。
    basis           text,
    basis_reference text,
    CONSTRAINT work_order_expected_one_per_material UNIQUE (work_order_id, material_id)
);

-- 【这一条必须是【单独一句 ALTER】,不能写进 CREATE TABLE 里】
-- CREATE TABLE 内联的 CHECK 【拿不到 NOT VALID】—— 建表时它一律被标成已校验,
-- 于是重建出来的库与线上差一个 NOT VALID 标记,而 gate 的镜像判词当场点名。
-- (PROC-SUPPORT-1 第一版就是这么写的,gate 报了唯一那一处 DIFFERENCE。)
-- 【而这个标记是【载荷】,不是排版】它就是"老行放过、新行必填"那条裁定本身:
-- 标成已校验,等于宣称既有那一行经受过检查,而 NOT VALID 的全部意义是它没有。
ALTER TABLE public.work_order_expected_outputs
    ADD CONSTRAINT work_order_expected_basis_required
    CHECK (basis IS NOT NULL AND basis IN ('planner_estimate','seeded_industry','calibrated'))
    NOT VALID;

COMMENT ON TABLE public.work_order_expected_outputs IS
    'WO-1a:预期产出 —— 【这里的数是排计划那个人的估计,不是一条标准】。
【为什么这句话必须写在表上】WO-1 的调查量过:今天这个库里【没有】任何可以推出预期产出的东西 —— 没有配方/BOM(Doc 2 明写它留给多工序那一次升级),投料侧 19 条含量行的 content_source 全是 NULL(一条化验来源都没有,PROC-1 刻意不回填),而两侧都测过的 (加工单, 金属) 组合【只有 3 个】。三个观测不是一个回收率。所以这个数只能是手敲的,而手敲的数与标准值意义完全不同:它比出来的差异是【估计 vs 实际】,不是【标准 vs 实际】。把它当标准读,会让一次估得保守的计划看起来像一次超产。
【行是可选的】没有行 = 没人记录过预期,而不是预期为零 —— 差异视图(WO-1b)必须把这两件事分开说。一个 COALESCE(...,0) 会把"没估过"变成"估了零",于是任何产出都是超额完成。
★【PROC-SUPPORT-1 兑现了这张表自己的那条规定】★ 上面那句「将来有了 BOM 怎么办 —— 它作为另一个带标签的来源进来(新列 basis/source,或另一张表),不覆盖这一张」,现在落地成了 basis / basis_reference 两列。**标签在,原来的估计一个字没动。**
【比例是逐投料种类的,而这一点是被【结构】满足的】work_order_id → work_orders → work_order_lines.material_id 就是"这张工单吃什么"。一张工单一套数字,不是一套全局数字。**这个要求是被满足的,不是被放弃的。**
【今天分不出组的那一半,照直说】materials 未软删 5 行里只有 1 行有 form_code、全 9 行里只有 2 行有 chemistry —— 所以"按 NMC/LFP 比较收率"今天【分不出组】。那不挡住本表,但它是一条具名缺口(见 docs/processing-support-as-built.md)。';

COMMENT ON COLUMN public.work_order_expected_outputs.basis IS
    'PROC-SUPPORT-1(R3):这个预期产出【是怎么来的】。三取一,**没有默认值**。
  planner_estimate  排计划的人估的(这张表按定义装的就是它)
  seeded_industry   照行业经验播下的低置信占位符 —— 它【不是】一条标准
  calibrated        对着真实生产校准过的
【为什么没有默认值】抄 metal_prices.source,连理由一起抄:「漏填就是一次失败,而不是悄悄补上一个看起来像答案的值」。
★【缺席的意思是"没有人说过"】★ 绝不许读成 calibrated,也绝不许在屏幕上显示成一个空白格 —— 空白格看起来像"这一栏不重要",而这一栏正是六个月后唯一能回答"这个数可不可信"的东西。
【它不覆盖 expected_qty】这是本表表注早就规定好的形状:新来源作为【另一个带标签的来源】进来,不覆盖既有的估计。混成一个数,两个数错的时候要找的人不是同一个。
【今天线上 calibrated 应当一次都不出现】真实炉次为 0。它第一次出现的那一天是一件大事,不是一次例行填表。';
COMMENT ON COLUMN public.work_order_expected_outputs.basis_reference IS
    'PROC-SUPPORT-1(R3):这个出处的【凭据】—— 哪一份行业报告、哪一次校准跑批、哪一个人的估计。
抄 metal_prices.source_reference,连它那句话一起抄:**自由文本是刻意的 —— 它是证据,不是数据。** 不要把它做成外键或字典:一份凭据可能是一封邮件、一份 PDF、一句"2026-09 与 PROC-2026-0xxx 对过",而把这些硬塞进一张字典表,得到的是一堆假的分类。';

ALTER TABLE public.work_order_expected_outputs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "work_order_expected_outputs select by permission" ON public.work_order_expected_outputs
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
