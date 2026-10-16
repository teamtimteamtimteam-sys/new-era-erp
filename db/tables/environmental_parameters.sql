-- db/tables/environmental_parameters.sql
-- MES-7b-2(2026-10-16,MES-0 功能 24 · Q75;MES-7b Step 0 Q16 · Q20,Tim):【一个监测的环境参数】—— 一张字典:代号、名字、单位、
--   以及它的限值(limit_value + limit_basis:max = 不许高于 · min = 不许低于)—— V20。
--   ★ 一个都不引导(Q16):监测哪些参数、限值是多少,是 NEA 执照给的,不是这里能编的。字典是空的时,待补的值页上 V20 一行;
--     有了参数之后,每一个启用的、没有限值的参数一行。没有限值的参数照样记得进结果,只是那一条读作"不判定"(not judged)。
--   ★ 限值与它的口径成对:要么都给、要么都空(ENV_LIMIT_NEEDS_BASIS —— 一个不说是上限还是下限的数判不了任何结果)。
--   ★ 一条结果在记下的那一刻把单位与限值【抄走】(environmental_results),所以这里改限值从不改写过去的结果。
--   ★ 一个参数被结果用过之后,它的代号冻住、不能删(ENV_PARAMETER_CODE_LOCKED|<代号>|<条数>,guard_environmental_parameter_code)。
--     名字、单位、限值、顺序、说明、启用照常可改。
--   RUNTIME CONFIG(引导刻意是空的,同在 check_mirrors 的 BOOTSTRAP_MAY_BE_EMPTY 里)。读 module.safety.view;写 module.safety.edit
--   (/settings/dictionaries,与表的写策略同一个码)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.environmental_parameters (
    code        text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name_en     text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh     text NOT NULL CHECK (btrim(name_zh) <> ''),
    is_active   boolean NOT NULL DEFAULT true,
    sort_order  integer NOT NULL DEFAULT 0,
    notes       text,
    unit        text NOT NULL CHECK (btrim(unit) <> ''),
    limit_value numeric,
    limit_basis text CHECK (limit_basis IN ('max', 'min')),
    CONSTRAINT environmental_parameters_limit_paired CHECK ((limit_value IS NULL) = (limit_basis IS NULL))
);

COMMENT ON TABLE public.environmental_parameters IS
    'MES-7b-2:监测的环境参数字典 —— 代号、名字、单位、限值(V20:limit_value + limit_basis max / min,成对;空 = Not yet set,结果读作不判定)。一个都不引导(参数与限值是 NEA 执照给的)。结果记下那一刻抄走单位与限值。被结果用过之后代号冻住。RUNTIME CONFIG。读 module.safety.view,写 module.safety.edit。';
COMMENT ON COLUMN public.environmental_parameters.limit_value IS
    'V20:这个参数的限值(与 limit_basis 成对)。空 = Not yet set —— 结果照样记得进,读作"不判定";待补的值页上它一行。由 NEA 执照给。';
COMMENT ON COLUMN public.environmental_parameters.limit_basis IS
    'max:结果高于限值就是超标 · min:结果低于限值就是超标。与 limit_value 成对。';

ALTER TABLE public.environmental_parameters ENABLE ROW LEVEL SECURITY;
CREATE POLICY "environmental_parameters select by permission" ON public.environmental_parameters
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
CREATE POLICY "environmental_parameters write by permission" ON public.environmental_parameters
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.safety.edit'::text)) WITH CHECK (has_permission('module.safety.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.environmental_parameters TO authenticated;
REVOKE ALL ON public.environmental_parameters FROM anon;

-- 限值与口径成对(按名说);被结果用过之后代号冻住、不能删。
CREATE TRIGGER trg_environmental_parameters_guard
    BEFORE INSERT OR UPDATE OR DELETE ON public.environmental_parameters
    FOR EACH ROW EXECUTE FUNCTION public.guard_environmental_parameter_code();

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.environmental_parameters
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.safety.edit');
