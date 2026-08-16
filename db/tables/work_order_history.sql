-- db/tables/work_order_history.sql
-- WO-1a:工单变更留痕(只增不改),形状取自 sales_order_history:成对的 old_/new_ + 必填理由;行 id 故意没有外键。
--
-- NOTE: introduced by db/migrations/2026-08-16-wo1a-work-order-document.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.work_order_history (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    work_order_id uuid NOT NULL REFERENCES public.work_orders (id),
    change_type   text NOT NULL CHECK (change_type IN
                  ('created','released','closed','cancelled',
                   'header_update','line_add','line_update','line_remove',
                   'expected_add','expected_update','expected_remove')),
    detail        text,
    changed_at    timestamptz NOT NULL DEFAULT now(),
    changed_by    uuid DEFAULT auth.uid(),
    -- 【行的 id 不加外键 —— 这是 SO-1b 学到的】留痕要活得比它记录的那一行久:
    -- 一条被删掉的计划行,它"曾经存在过、被谁在什么时候删的"正是留痕的全部意义。
    -- 加了外键,删行要么被拦、要么把留痕一起带走,两种都是错的。
    work_order_line_id     uuid,
    work_order_expected_id uuid,
    -- 表头可改字段的成对值
    old_scheduled_date date,
    new_scheduled_date date,
    old_notes          text,
    new_notes          text,
    -- 行可改字段的成对值(计划量 / 预期量共用这一对 —— 两者都是"一个数",
    -- 而 change_type 已经说清了是哪一种行)
    old_qty            numeric,
    new_qty            numeric,
    -- 行归属的物料(行删掉之后,留痕仍要说得出"删的是哪一种料")
    material_id        uuid,
    amend_reason       text
);

COMMENT ON COLUMN public.work_order_history.work_order_line_id IS
    '哪一条计划行(行改动才有)。【故意没有外键】—— 留痕要活得比行久:一条被删掉的行"曾经存在、被谁删的"正是留痕的意义所在(与 sales_order_history 同一条)。';

ALTER TABLE public.work_order_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "work_order_history select by permission" ON public.work_order_history
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
