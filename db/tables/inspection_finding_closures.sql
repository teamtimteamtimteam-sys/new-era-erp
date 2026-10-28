-- db/tables/inspection_finding_closures.sql
-- MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q14,Tim):【一条巡检发现的关闭】—— 做了什么、谁、什么时候。一条发现最多关一次(UNIQUE);
--   写下就不改不删。关一条发现与关它那张任务是两件事:任务关了,发现照旧开着(Q14)。
--   【写】只经 close_inspection_finding(module.safety.edit);会话里直连插入按名拒 INSPECTION_THROUGH_FUNCTION_ONLY。【读】module.safety.view。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.inspection_finding_closures (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    finding_id    uuid NOT NULL UNIQUE REFERENCES public.inspection_findings (id),
    what_was_done text NOT NULL CHECK (btrim(what_was_done) <> ''),
    closed_at     timestamptz NOT NULL DEFAULT now(),
    closed_by     uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.inspection_finding_closures IS
    'MES-7b-2:一条巡检发现的关闭 —— 做了什么、谁、什么时候;每条发现最多一行,写下就不改。关掉它那张任务不等于关闭它。写只经 close_inspection_finding(module.safety.edit)。读 module.safety.view。';

ALTER TABLE public.inspection_finding_closures ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inspection_finding_closures select by permission" ON public.inspection_finding_closures
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.safety.view'::text)));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inspection_finding_closures TO authenticated;
REVOKE ALL ON public.inspection_finding_closures FROM anon;

CREATE TRIGGER trg_inspection_finding_closures_insert
    BEFORE INSERT ON public.inspection_finding_closures
    FOR EACH ROW EXECUTE FUNCTION public.guard_inspection_record_write();
CREATE TRIGGER trg_inspection_finding_closures_immutable
    BEFORE UPDATE OR DELETE ON public.inspection_finding_closures
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_inspection_record_write();
CREATE TRIGGER trg_inspection_finding_closures_truncate
    BEFORE TRUNCATE ON public.inspection_finding_closures
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
