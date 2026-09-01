-- db/tables/shift_handover_items.sql
-- PROC-SUPPORT-1(R4):交接班的逐条内容 —— 内容是【行】,不是列。
--
-- NOTE: introduced by db/migrations/2026-09-01-procsupport1-a-an-operation-is-not-optional.sql.

CREATE TABLE public.shift_handover_items (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    handover_id    uuid NOT NULL REFERENCES public.shift_handovers (id) ON DELETE CASCADE,
    item_type_code text NOT NULL REFERENCES public.handover_item_types (code),
    body           text NOT NULL,
    sort_order     integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    CONSTRAINT shift_handover_item_body_stated CHECK (btrim(body) <> '')
);

COMMENT ON TABLE public.shift_handover_items IS
    'PROC-SUPPORT-1(R4):交接班的逐条内容。**一类内容可以有【多条】** —— 三件没做完的活是三行,不是一段挤在一起的文字,因为下一个班要一件一件地接。
【为什么没有 (handover_id, item_type_code) 唯一约束】那会把"三件未完成的工作"压成一行文本,而**一段文本没法逐件被接手、被划掉**。
【body 不许是空串】一条内容为空的条目与没有这条条目是同一件事,而它会在计数里冒充"填过了"。';

ALTER TABLE public.shift_handover_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shift_handover_items select by permission" ON public.shift_handover_items
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
CREATE POLICY "shift_handover_items write by permission" ON public.shift_handover_items
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shift_handover_items TO authenticated;
