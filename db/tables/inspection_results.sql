-- db/tables/inspection_results.sql
-- MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q13,Tim):【一次巡检里一项的结果】—— pass(合格)· fail(不合格)· na(不适用)。
--   检查项的字在记下的那一刻从清单抄进来(item_text),于是改清单从不改写它。不合格必须写一句说明(note)—— 表上的 CHECK 与
--   record_inspection_run 的 INSPECTION_FAIL_NOTE_REQUIRED|<项> 说的是同一句话。清单上的每一项恰好一行。
--   写下就不改不删(INSPECTION_RECORD_IMMUTABLE);只经 record_inspection_run 写(INSPECTION_THROUGH_FUNCTION_ONLY)。读 module.safety.view。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.inspection_results (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id    uuid NOT NULL REFERENCES public.inspection_runs (id),
    position  integer NOT NULL CHECK (position > 0),
    item_text text NOT NULL CHECK (btrim(item_text) <> ''),
    result    text NOT NULL CHECK (result IN ('pass', 'fail', 'na')),
    note      text,
    CONSTRAINT inspection_results_position UNIQUE (run_id, position),
    -- 不合格要说为什么
    CONSTRAINT inspection_results_fail_note CHECK (result <> 'fail' OR (note IS NOT NULL AND btrim(note) <> ''))
);

COMMENT ON TABLE public.inspection_results IS
    'MES-7b-2:一次巡检里一项的结果 —— pass · fail · na;检查项的字是记下那一刻从清单抄来的;不合格必须有说明。清单上每一项恰好一行。写下就不改,只经 record_inspection_run。读 module.safety.view。';

ALTER TABLE public.inspection_results ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inspection_results select by permission" ON public.inspection_results
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.safety.view'::text)));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inspection_results TO authenticated;
REVOKE ALL ON public.inspection_results FROM anon;

CREATE TRIGGER trg_inspection_results_insert
    BEFORE INSERT ON public.inspection_results
    FOR EACH ROW EXECUTE FUNCTION public.guard_inspection_record_write();
CREATE TRIGGER trg_inspection_results_immutable
    BEFORE UPDATE OR DELETE ON public.inspection_results
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_inspection_record_write();
CREATE TRIGGER trg_inspection_results_truncate
    BEFORE TRUNCATE ON public.inspection_results
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
