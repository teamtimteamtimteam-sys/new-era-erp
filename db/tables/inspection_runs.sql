-- db/tables/inspection_runs.sql
-- MES-7b-2(2026-10-16,MES-0 功能 23 · Q53 · Q72;MES-7b Step 0 Q13 · Q27,Tim):【一次安全巡检】—— 照一张清单巡了一遍:什么时候、谁巡的
--   (一名员工)、可选地在哪个库位 / 哪台机器;每一项的结果在 inspection_results。
--   【编号】INS-YYYY-NNNN,按年、无洞(next_inspection_code;document_types 的 'inspection';宽度 GREATEST(4, 位数) —— CODE-WIDTH-4)。
--   【抄下来】清单的代号、名字、片区在记下的那一刻抄进这一行(template_code / template_name / template_area),检查项的字抄进结果 ——
--     改一张清单从不改写一次过去的巡检(Q13)。
--   【一次交完,交了就不改】(Q13)结果与发现一次提交(record_inspection_run)。写下之后这一行与它的结果对谁都不改、不删
--     (INSPECTION_RECORD_IMMUTABLE)。记错了 = 再记一次,引用它、带理由(corrects_run_id + correction_reason):原来那一次从此
--     "已被更正",一次巡检最多被更正一次(UNIQUE)—— 要再改,就更正那一次更正。
--   【写】只经 record_inspection_run(module.safety.edit);会话里直连插入按名拒 INSPECTION_THROUGH_FUNCTION_ONLY。
--   【读】module.safety.view。没有审批(Q18:一次巡检是一件发生过的事的记录)。没有金额。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.inspection_runs (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                  text NOT NULL UNIQUE,
    template_id           uuid NOT NULL REFERENCES public.inspection_templates (id),
    template_code         text NOT NULL,
    template_name         text NOT NULL,
    template_area         text NOT NULL,
    inspected_at          timestamptz NOT NULL,
    inspector_employee_id uuid NOT NULL REFERENCES public.employees (id),
    location_id           uuid REFERENCES public.storage_locations (id),
    equipment_id          uuid REFERENCES public.fixed_assets (id),
    notes                 text,
    corrects_run_id       uuid UNIQUE REFERENCES public.inspection_runs (id),
    correction_reason     text,
    recorded_at           timestamptz NOT NULL DEFAULT now(),
    recorded_by           uuid DEFAULT auth.uid(),
    -- 一次更正必须说出它更正哪一次、为什么;不是更正的就两样都没有
    CONSTRAINT inspection_runs_correction CHECK (
        (corrects_run_id IS NULL AND correction_reason IS NULL)
        OR (corrects_run_id IS NOT NULL AND correction_reason IS NOT NULL AND btrim(correction_reason) <> '')),
    CONSTRAINT inspection_runs_not_self CHECK (corrects_run_id IS DISTINCT FROM id)
);

CREATE INDEX inspection_runs_template_id_rel ON public.inspection_runs (template_id);
CREATE INDEX inspection_runs_inspector_employee_id_rel ON public.inspection_runs (inspector_employee_id);
CREATE INDEX inspection_runs_location_id_rel ON public.inspection_runs (location_id);
CREATE INDEX inspection_runs_equipment_id_rel ON public.inspection_runs (equipment_id);
CREATE INDEX inspection_runs_code_trgm ON public.inspection_runs USING gin (code extensions.gin_trgm_ops);

COMMENT ON TABLE public.inspection_runs IS
    'MES-7b-2:一次安全巡检(INS-YYYY-NNNN,按年无洞)—— 照一张清单(代号 / 名字 / 片区在记下那一刻抄进来)、什么时候、谁巡的、可选的库位与机器;每一项的结果在 inspection_results,发现在 inspection_findings。一次交完,交了就不改不删;记错了再记一次、引用它、带理由(一次最多被更正一次)。写只经 record_inspection_run(module.safety.edit)。读 module.safety.view。';
COMMENT ON COLUMN public.inspection_runs.corrects_run_id IS
    '这一次巡检更正的那一次(带 correction_reason)。被更正的那一次照旧读得到,页面上标"已被更正";一次巡检最多被更正一次。';

ALTER TABLE public.inspection_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inspection_runs select by permission" ON public.inspection_runs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inspection_runs TO authenticated;
REVOKE ALL ON public.inspection_runs FROM anon;

-- 插入(行级):直连按名拒;时刻不在未来 —— 对每一个写入者都成立。改与删(语句级):对谁都按名拒。
CREATE TRIGGER trg_inspection_runs_insert
    BEFORE INSERT ON public.inspection_runs
    FOR EACH ROW EXECUTE FUNCTION public.guard_inspection_record_write();
CREATE TRIGGER trg_inspection_runs_immutable
    BEFORE UPDATE OR DELETE ON public.inspection_runs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_inspection_record_write();
CREATE TRIGGER trg_inspection_runs_truncate
    BEFORE TRUNCATE ON public.inspection_runs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
