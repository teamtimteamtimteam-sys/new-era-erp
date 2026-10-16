-- db/tables/environmental_results.sql
-- MES-7b-2(2026-10-16,MES-0 功能 24 · Q75;MES-7b Step 0 Q16,Tim):【一条环境监测结果】—— 一家实验室对一个参数在一个采样点、一天的读数:
--   参数、采样点、采样日(不在未来)、实验室(laboratories)、报告编号、数值。
--   【抄下来】那一刻的单位与限值(unit / limit_value / limit_basis)从参数字典抄进这一行 —— 改字典从不改写一条过去的结果。
--   【判定】exceeds:有限值时 = 高于上限(max)/ 低于下限(min);没有限值时为空 = "不判定"(not judged)。表上的 CHECK 把判定与
--     抄下来的限值钉在一起:任何写入者都写不出一个与自己的数对不上的判定。
--   【超标开一件事故】(Q16 · MES-0 Q75)一条超标的结果在【同一笔事务里】开一件种类 emission_exceedance 的事故(incident_id 指着它;
--     record_environmental_result 调 record_incident)。CHECK:超标 ⇔ 指着一件事故。要不要通报 NEA 由记录的人回答 —— 超标而没回答,
--     那一条按名拒(ENV_EXCEEDANCE_NEA_ANSWER_REQUIRED),当场做了什么也要写(ENV_EXCEEDANCE_ACTION_REQUIRED)。
--   【只追加】(Q16)写下就不改不删(ENV_RESULT_IMMUTABLE)。记错了 = 再记一条、引用它、带理由(corrects_result_id,一条最多被更正一次)。
--     更正的那一条照样判定;它更正的那一条若已经开过一件事故,而这一条仍超标,就指着同一件 —— 一件事不开两件事故。
--   【写】只经 record_environmental_result(module.safety.edit);会话里直连插入按名拒 ENV_RESULT_THROUGH_FUNCTION_ONLY。
--   【读】module.safety.view。没有金额。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.environmental_results (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    parameter_code     text NOT NULL REFERENCES public.environmental_parameters (code),
    sample_point       text NOT NULL CHECK (btrim(sample_point) <> ''),
    sampled_on         date NOT NULL,
    laboratory_code    text NOT NULL REFERENCES public.laboratories (code),
    report_reference   text NOT NULL CHECK (btrim(report_reference) <> ''),
    value              numeric NOT NULL,
    unit               text NOT NULL CHECK (btrim(unit) <> ''),
    limit_value        numeric,
    limit_basis        text CHECK (limit_basis IN ('max', 'min')),
    exceeds            boolean,
    incident_id        uuid REFERENCES public.incidents (id),
    corrects_result_id uuid UNIQUE REFERENCES public.environmental_results (id),
    correction_reason  text,
    recorded_at        timestamptz NOT NULL DEFAULT now(),
    recorded_by        uuid DEFAULT auth.uid(),
    CONSTRAINT environmental_results_limit_paired CHECK ((limit_value IS NULL) = (limit_basis IS NULL)),
    -- 判定与抄下来的限值钉在一起:没有限值 ⇔ 不判定;有限值时判定就是那一次比较
    CONSTRAINT environmental_results_judgement CHECK (
        (limit_value IS NULL AND exceeds IS NULL)
        OR (limit_basis = 'max' AND exceeds IS NOT NULL AND exceeds = (value > limit_value))
        OR (limit_basis = 'min' AND exceeds IS NOT NULL AND exceeds = (value < limit_value))),
    -- 超标 ⇔ 指着一件事故
    CONSTRAINT environmental_results_exceedance_incident CHECK ((exceeds IS TRUE) = (incident_id IS NOT NULL)),
    CONSTRAINT environmental_results_correction CHECK (
        (corrects_result_id IS NULL AND correction_reason IS NULL)
        OR (corrects_result_id IS NOT NULL AND correction_reason IS NOT NULL AND btrim(correction_reason) <> '')),
    CONSTRAINT environmental_results_not_self CHECK (corrects_result_id IS DISTINCT FROM id)
);

CREATE INDEX environmental_results_parameter_code_rel ON public.environmental_results (parameter_code);
CREATE INDEX environmental_results_laboratory_code_rel ON public.environmental_results (laboratory_code);
CREATE INDEX environmental_results_incident_id_rel ON public.environmental_results (incident_id);

COMMENT ON TABLE public.environmental_results IS
    'MES-7b-2:一条环境监测结果 —— 参数、采样点、采样日、实验室、报告编号、数值;单位与限值在记下那一刻从字典抄来;exceeds = 判定(没有限值时为空 = 不判定)。超标在同一笔事务里开一件 emission_exceedance 事故(incident_id)。只追加,更正是一条引用它、带理由的新结果。写只经 record_environmental_result(module.safety.edit)。读 module.safety.view。';
COMMENT ON COLUMN public.environmental_results.exceeds IS
    '判定:true 超标 · false 在限值之内 · 空 = 不判定(记下那一刻这个参数没有限值 —— V20 Not yet set)。';
COMMENT ON COLUMN public.environmental_results.incident_id IS
    '超标时它开的那一件 emission_exceedance 事故(同一笔事务)。一条更正若仍超标、而它更正的那一条已经开过一件,就指着同一件。';

ALTER TABLE public.environmental_results ENABLE ROW LEVEL SECURITY;
CREATE POLICY "environmental_results select by permission" ON public.environmental_results
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.environmental_results TO authenticated;
REVOKE ALL ON public.environmental_results FROM anon;

CREATE TRIGGER trg_environmental_results_insert
    BEFORE INSERT ON public.environmental_results
    FOR EACH ROW EXECUTE FUNCTION public.guard_environmental_result_write();
CREATE TRIGGER trg_environmental_results_immutable
    BEFORE UPDATE OR DELETE ON public.environmental_results
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_environmental_result_write();
CREATE TRIGGER trg_environmental_results_truncate
    BEFORE TRUNCATE ON public.environmental_results
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
