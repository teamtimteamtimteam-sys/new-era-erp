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
    CONSTRAINT work_order_expected_one_per_material UNIQUE (work_order_id, material_id)
);

COMMENT ON TABLE public.work_order_expected_outputs IS
    'WO-1a:预期产出 —— 【这里的数是排计划那个人的估计,不是一条标准】。
【为什么这句话必须写在表上】WO-1 的调查量过:今天这个库里【没有】任何可以推出预期产出的东西 —— 没有配方/BOM(Doc 2 明写它留给多工序那一次升级),投料侧 19 条含量行的 content_source 全是 NULL(一条化验来源都没有,PROC-1 刻意不回填),而两侧都测过的 (加工单, 金属) 组合【只有 3 个】。三个观测不是一个回收率。所以这个数只能是手敲的,而手敲的数与标准值意义完全不同:它比出来的差异是【估计 vs 实际】,不是【标准 vs 实际】。把它当标准读,会让一次估得保守的计划看起来像一次超产。
【行是可选的】没有行 = 没人记录过预期,而不是预期为零 —— 差异视图(WO-1b)必须把这两件事分开说。一个 COALESCE(...,0) 会把"没估过"变成"估了零",于是任何产出都是超额完成。
【将来有了 BOM 怎么办】它作为【另一个带标签的来源】进来(新列 basis/source,或另一张表),【不覆盖这一张】。覆盖会把"人估的"与"标准算的"混成一个数,而那两个数错的时候要找的人不是同一个。';

ALTER TABLE public.work_order_expected_outputs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "work_order_expected_outputs select by permission" ON public.work_order_expected_outputs
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
