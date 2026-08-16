-- db/tables/work_order_lines.sql
-- WO-1a:计划投料行 —— 按【物料】,一种物料一行(唯一约束),这是计划与实绩相比时的唯一读法。
--
-- NOTE: introduced by db/migrations/2026-08-16-wo1a-work-order-document.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.work_order_lines (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    work_order_id uuid NOT NULL REFERENCES public.work_orders (id) ON DELETE RESTRICT,
    material_id   uuid NOT NULL REFERENCES public.materials (id),
    planned_qty   numeric NOT NULL CHECK (planned_qty > 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    -- 【一种物料一行 —— 这是那条写下来的映射规则】计划按【物料】写(计划的时候
    -- 那批货可能还没到,更没人挑过批次;挑批次是车间当天的事)。而实绩按【批次】
    -- 记。两者相比时,"计划 5 吨黑粉,实际吃了 A 批 3 吨、B 批 2.5 吨"要有唯一
    -- 读法 —— 允许同一物料两行,差异就再也说不清是哪一行超了。
    CONSTRAINT work_order_lines_one_per_material UNIQUE (work_order_id, material_id)
);

COMMENT ON TABLE public.work_order_lines IS
    'WO-1a:计划投料。【按物料,不按批次】—— 排计划的时候批次往往还不存在;挑批次是开工当天的决定。与实绩相比时的唯一读法由 (work_order_id, material_id) 的唯一约束保证。';

ALTER TABLE public.work_order_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "work_order_lines select by permission" ON public.work_order_lines
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
