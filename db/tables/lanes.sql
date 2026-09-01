-- db/tables/lanes.sql
-- LOG-1a。镜像与 db/migrations/2026-08-19-log1a-*.sql 同源。

CREATE TABLE public.lanes (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    origin_port_id       uuid NOT NULL REFERENCES public.ports (id),
    destination_port_id  uuid NOT NULL REFERENCES public.ports (id),
    checklist_reviewed_at timestamptz,
    deleted_at           timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    CONSTRAINT lanes_distinct_ports CHECK (origin_port_id <> destination_port_id),
    CONSTRAINT lanes_unique_pair UNIQUE (origin_port_id, destination_port_id)
);

COMMENT ON TABLE public.lanes IS
'LOG-1a:航段 = 起运港 → 目的港。**除此之外什么都没有** —— 承运方式、船公司、时效都不在这里:
航段是"从哪到哪"这个事实,谁来跑、多少钱、要什么单据都挂在它上面,而不是长进它里面。';

COMMENT ON COLUMN public.lanes.checklist_reviewed_at IS
'LOG-1a:这条航段的单据清单【被人定过了没有】。NULL = 从来没定过 —— 那是一个具名状态,不是"不需要任何单据"。
两者在屏幕上必须是两句话:一条没人看过的航段与一条确认过"确实什么都不要"的航段,风险完全不同。
本列由人在确认清单时写,系统永不推断。';

ALTER TABLE public.lanes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "lanes select" ON public.lanes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.logistics.view'::text));
CREATE POLICY "lanes write" ON public.lanes
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));
