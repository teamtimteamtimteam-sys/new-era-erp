-- db/tables/processing_run_corrections.sql
-- MES-4a(2026-10-07,规格 §4.2;MES-0 Q49;MES-4a Step 0 Q30,Tim):【加工单表头的更正】—— 只追加。
--   只有六个字段改得了:开始 · 结束 · 班次 · 机器 · 配方版本 · 备注(correct_run_header)。一次更正 = 一行:哪个字段、原来是什么、
--   改成什么、为什么(必填)、谁、何时;表头随之改成新值 —— 原值留在这里与变更记录里。
--   【改不了的】加工日、数量、工序、工单:那些改了就是另一炉 —— 走回滚申请(CFO)+ 一张新单带 corrects_run_id(Q31)。
--   UPDATE / DELETE / TRUNCATE 语句级拒。读:module.processing.view。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_run_corrections (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       uuid NOT NULL REFERENCES public.processing_runs (id),
    field        text NOT NULL CHECK (field IN ('started_at', 'ended_at', 'shift_code', 'equipment_id', 'recipe_version_id', 'notes')),
    old_value    text,
    new_value    text,
    reason       text NOT NULL CHECK (btrim(reason) <> ''),
    corrected_at timestamptz NOT NULL DEFAULT now(),
    corrected_by uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.processing_run_corrections IS
    'MES-4a:加工单表头的更正,只追加 —— 开始 · 结束 · 班次 · 机器 · 配方版本 · 备注六个字段;原值、新值、理由(必填)、谁、何时。加工日、数量、工序、工单不在这里改(回滚 + 新单)。';

CREATE INDEX processing_run_corrections_run ON public.processing_run_corrections (run_id);

CREATE TRIGGER trg_processing_run_corrections_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_corrections
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.processing_run_corrections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_corrections select by permission" ON public.processing_run_corrections
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.processing_run_corrections TO authenticated;
REVOKE ALL ON public.processing_run_corrections FROM anon;
