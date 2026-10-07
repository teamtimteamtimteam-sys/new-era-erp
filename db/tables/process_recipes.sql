-- db/tables/process_recipes.sql
-- MES-4a(2026-10-07,MES-0 Q44 · MES-4a Step 0 Q16,Tim):【配方】—— 一道工序上一组有名字的参数预设。
--   一个配方只是一个名字(code 由人敲,不走单据前缀 —— document_type_exceptions 里有一行);它的内容住在
--   process_recipe_versions 里,一版一行、写了就不改。加工单记它用的是【哪一版】(processing_runs.recipe_version_id)。
--   停用(is_active = false)= 以后别再选它;已经用过它的加工单不受影响。读:module.processing.view;写:module.processing.edit。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.process_recipes (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_type_code text NOT NULL REFERENCES public.operation_types (code),
    code                text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]*$'),
    name_en             text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh             text NOT NULL CHECK (btrim(name_zh) <> ''),
    is_active           boolean NOT NULL DEFAULT true,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.process_recipes IS
    'MES-4a:一道工序上的一个配方(有名字的参数预设,MES-0 Q44)。内容在 process_recipe_versions(一版一行,写了不改);加工单记它用的那一版。code 由人敲(大写、数字、- 与 _),不走单据前缀。';

CREATE INDEX process_recipes_operation ON public.process_recipes (operation_type_code);

CREATE OR REPLACE FUNCTION public.guard_process_recipe()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'RECIPE_RETIRE_NOT_DELETE|%', OLD.code;
    END IF;
    -- 一个配方属于哪道工序、叫什么码,定了就不改 —— 它的每一版都是按那道工序的参数写的
    IF NEW.operation_type_code IS DISTINCT FROM OLD.operation_type_code OR NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'RECIPE_KEY_FIXED|%', OLD.code;
    END IF;
    NEW.updated_at := now();
    NEW.updated_by := auth.uid();
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_process_recipes_guard
    BEFORE UPDATE OR DELETE ON public.process_recipes
    FOR EACH ROW EXECUTE FUNCTION public.guard_process_recipe();

ALTER TABLE public.process_recipes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "process_recipes select by permission" ON public.process_recipes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "process_recipes insert by permission" ON public.process_recipes
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.processing.edit'::text));
CREATE POLICY "process_recipes update by permission" ON public.process_recipes
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE ON public.process_recipes TO authenticated;
REVOKE ALL ON public.process_recipes FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.process_recipes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
