-- db/tables/process_recipe_versions.sql
-- MES-4a(2026-10-07,MES-0 Q44 · MES-4a Step 0 Q16,Tim):【配方的一版】—— 写了就不改(只追加)。
--   param_values = {字段码: 值},只许是这道工序上【启用着的参数】(parameter;指标是结果,不是预设 —— RECIPE_FIELD_NOT_A_PARAMETER),
--   每个值按字段的类型验(数、计数、文字、是/否)。要改就再出一版(version + 1)。
--   只经 create_recipe_version(module.processing.edit)写;UPDATE / DELETE / TRUNCATE 语句级拒(APPEND_ONLY)。
--   加工单记的是【这一版的 id】,于是"这一炉照哪一版跑的"永远答得出来,哪怕配方后来又出了新版。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.process_recipe_versions (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    recipe_id  uuid NOT NULL REFERENCES public.process_recipes (id),
    version    integer NOT NULL CHECK (version >= 1),
    param_values jsonb NOT NULL CHECK (jsonb_typeof(param_values) = 'object'),
    notes      text,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid DEFAULT auth.uid(),
    UNIQUE (recipe_id, version)
);

COMMENT ON TABLE public.process_recipe_versions IS
    'MES-4a:配方的一版(只追加)。param_values = {字段码: 值},只收这道工序上启用的参数。改配方 = 出新一版;加工单记它用的那一版。只经 create_recipe_version 写。';

CREATE TRIGGER trg_process_recipe_versions_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.process_recipe_versions
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.process_recipe_versions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "process_recipe_versions select by permission" ON public.process_recipe_versions
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.process_recipe_versions TO authenticated;
REVOKE ALL ON public.process_recipe_versions FROM anon;
