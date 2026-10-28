-- db/tables/incident_kinds.sql
-- MES-7b-1(2026-10-16,MES-0 功能 24 · Q73;MES-7b Step 0 Q4,Tim):【一件事故是哪一种】—— 一张可编辑的清单。
--   引导七种:规格书要 ERP 当作异常收下的那几样安全信号(热失控 · 起火冒烟 · 气体释放(电解液蒸汽 / HF)· 粉尘浓度),
--   WSH 登记簿的工伤与未遂(docs/forward-queue.md:2402),以及排放超标(MES-0 Q75,环境监测在 MES-7b-2 来)。
--   ★ 没有 other:一件说不出是哪一种的事故,与"其它"那个兜底桶是同一个病(规格 §4.1 对损耗、downtime_causes 对停机说的同一句话)。
--     加一种是加一行(/settings/dictionaries,module.safety.edit)。
--   ★ 一种被事故引用之后,它的代号冻住(guard_incident_kind_code,INCIDENT_KIND_CODE_LOCKED|<代号>|<件数>)—— 改代号就是改外键指着的
--     东西,删它就是让一件事故说不出自己是哪一种。名字、顺序、说明、启用照常可改;停用只管"以后还能不能新选"。
--   RUNTIME CONFIG。读:module.safety.view;写:module.safety.edit(与表的写策略同一个码 —— 字典页的门照它)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.incident_kinds (
    code       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$' AND code <> 'other'),
    name_en    text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh    text NOT NULL CHECK (btrim(name_zh) <> ''),
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.incident_kinds IS
    'MES-7b-1:事故的种类(没有 other)。引导七种:thermal_runaway · fire_smoke · gas_release · dust_concentration · injury · near_miss · emission_exceedance。被一件事故引用之后代号冻住(INCIDENT_KIND_CODE_LOCKED)。RUNTIME CONFIG。读 module.safety.view,写 module.safety.edit。';

INSERT INTO public.incident_kinds (code, name_en, name_zh, sort_order, notes) VALUES
    ('thermal_runaway', 'Thermal runaway', '热失控', 10, 'A cell or module heating out of control (temperature or rate of rise beyond the site interlock).'),
    ('fire_smoke', 'Fire or smoke', '起火或冒烟', 20, 'Fire, flame or smoke anywhere on site.'),
    ('gas_release', 'Gas release', '气体释放', 30, 'Electrolyte vapour, HF or another gas released.'),
    ('dust_concentration', 'Dust concentration', '粉尘浓度', 40, 'Dust concentration beyond the site alarm (powder stripping, black mass handling).'),
    ('injury', 'Injury', '工伤', 50, 'A person was hurt at work.'),
    ('near_miss', 'Near miss', '未遂事件', 60, 'Something that could have hurt someone or caused damage, but did not.'),
    ('emission_exceedance', 'Emission exceedance', '排放超标', 70, 'A monitored emission above its licence limit.');

ALTER TABLE public.incident_kinds ENABLE ROW LEVEL SECURITY;
CREATE POLICY "incident_kinds select by permission" ON public.incident_kinds
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.safety.view'::text)));
CREATE POLICY "incident_kinds write by permission" ON public.incident_kinds
    AS PERMISSIVE FOR ALL TO authenticated
    USING ((SELECT has_permission('module.safety.edit'::text))) WITH CHECK ((SELECT has_permission('module.safety.edit'::text)));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.incident_kinds TO authenticated;
REVOKE ALL ON public.incident_kinds FROM anon;

-- 被引用之后代号冻住、不能删(外键也挡删除,但那是一串约束名;这里按名说出被引用几件)。
CREATE TRIGGER trg_incident_kinds_code_locked
    BEFORE UPDATE OR DELETE ON public.incident_kinds
    FOR EACH ROW EXECUTE FUNCTION public.guard_incident_kind_code();

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.incident_kinds
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.safety.edit');
