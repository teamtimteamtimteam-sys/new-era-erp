-- db/tables/compliance_settings.sql
-- MES-8b-1(2026-10-17,MES-0 §5.1 V26 · V27 · Q82 · Q93;MES-8 Step 0 Q14 · Q18 · Q28,Tim):【合规包的两个待补的值 —— 单行】。
--   V26  nea_return_format · nea_return_frequency   NEA 申报的格式与频率(NEA 执照下来时由执照写明)。
--   V27  eu_efficiency_method · eu_efficiency_targets  欧盟回收效率的计算方法与目标(欧盟实施条例或欧盟买家给出)。
--   【引导一律为空】(Q18):这一行在线上从第一天起就是两行待补的值(V18 / V20 的先例:一本空的字典也是一行)。
--   【填了也不算任何东西】(Q28):合规包把这几句话照原样印进第 7、8 节;本刀不按它们算 NEA 申报表、不算回收效率 —— 那是 V27 给了之后
--   自己那一刀的事。每一份冻下来的包把【当时】这一行抄进 payload,所以改这一行永远不改写一份过去的包。
--   由 action.compliance_pack 经 set_compliance_settings 改;修改史在变更记录里(主语 compliance_settings,画在合规包页)。
--   RUNTIME CONFIG:Tim 设一次,线上就与本文件不同 —— 那是系统在正常工作(supplier_score_settings 的先例)。
--
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.compliance_settings (
    id                    boolean PRIMARY KEY DEFAULT true CHECK (id),
    nea_return_format     text CHECK (nea_return_format IS NULL OR btrim(nea_return_format) <> ''),
    nea_return_frequency  text CHECK (nea_return_frequency IS NULL OR btrim(nea_return_frequency) <> ''),
    eu_efficiency_method  text CHECK (eu_efficiency_method IS NULL OR btrim(eu_efficiency_method) <> ''),
    eu_efficiency_targets text CHECK (eu_efficiency_targets IS NULL OR btrim(eu_efficiency_targets) <> ''),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    updated_by            uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.compliance_settings IS
    'MES-8b-1:合规包的设定(单行)。V26 = nea_return_format · nea_return_frequency(NEA 申报的格式与频率);V27 = eu_efficiency_method · eu_efficiency_targets(欧盟回收效率的方法与目标)。引导一律为空(Q18)。只是被印进合规包的几句话 —— 本刀不按它们算任何东西(Q28)。每一份冻下来的包抄走这一行。action.compliance_pack 经 set_compliance_settings 改。';
COMMENT ON COLUMN public.compliance_settings.nea_return_format IS
    'V26:NEA 申报的格式(执照写明的那一份表)。空 = Not yet set(合规包第 7 节读「NEA return — format not yet set (V26)」)。';
COMMENT ON COLUMN public.compliance_settings.nea_return_frequency IS
    'V26:NEA 申报的频率。与格式一起才算给了。';
COMMENT ON COLUMN public.compliance_settings.eu_efficiency_method IS
    'V27:欧盟回收效率的计算方法(实施条例 / 欧盟买家)。空 = Not yet set(第 8 节读「EU recycling efficiency — method not yet set (V27)」)。';
COMMENT ON COLUMN public.compliance_settings.eu_efficiency_targets IS
    'V27:欧盟回收效率的目标。与方法一起才算给了。';

INSERT INTO public.compliance_settings (id) VALUES (true);

CREATE TRIGGER trg_compliance_settings_updated_at
    BEFORE UPDATE ON public.compliance_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.compliance_settings ENABLE ROW LEVEL SECURITY;
-- 读:合规的查看码(合规包页的设定面板、待补的值那两行)。写只经函数。
CREATE POLICY "compliance_settings select by permission" ON public.compliance_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.compliance.view'::text)));
GRANT SELECT ON public.compliance_settings TO authenticated;
REVOKE ALL ON public.compliance_settings FROM anon;
