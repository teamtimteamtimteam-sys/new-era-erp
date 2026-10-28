-- db/tables/safety_settings.sql
-- MES-7b-1(2026-10-16,MES-0 §5.1 V19 · Q74;MES-7b Step 0 Q10 · Q11,Tim):【安全的设定 —— 单行】。今天只有一样:V19。
--   nea_report_working_days —— 一件要向 NEA 通报的事故,书面报告要在几个【工作日】内交。
--     期限 = 从事故日(新加坡日期)之后的第一个工作日数起,数到第 V19 个工作日(business_days_after,公共假期表与 is_business_day)。
--   ★ Q11(Tim):引导存 2,【未确认】—— 出处是仓库里那一条义务的记录(docs/forward-queue.md:2402,「立即通报 … 两个工作日内提交书面报告」),
--     不是执照原文。所以 confirmed_at 为空:页面上的期限一律标"未确认",V19 一直挂在待补的值上,直到持 module.safety.edit 的人
--     对着执照把它确认(set_safety_settings 带 p_confirmed = true)。改天数不带确认 = 又回到未确认。
--   空(NULL)= Not yet set:书面报告的期限算不出来(屏幕上说"期限没有设定"),通报的提醒照旧。
--   由 module.safety.edit 经 set_safety_settings 改;修改史在变更记录里(主语 safety_settings,画在 /safety/incidents)。
--   RUNTIME CONFIG:Tim 确认一次,线上就与本文件不同 —— 那是系统在正常工作(quality_settings 的先例)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.safety_settings (
    id                           boolean PRIMARY KEY DEFAULT true CHECK (id),
    nea_report_working_days      integer CHECK (nea_report_working_days IS NULL OR nea_report_working_days > 0),
    nea_report_days_source       text,
    nea_report_days_confirmed_at timestamptz,
    nea_report_days_confirmed_by uuid,
    updated_at                   timestamptz NOT NULL DEFAULT now(),
    updated_by                   uuid DEFAULT auth.uid(),
    -- 确认的是一个数:没有数就没有确认;确认与确认人同进同出
    CONSTRAINT safety_settings_confirmation_consistent CHECK (
        (nea_report_days_confirmed_at IS NULL AND nea_report_days_confirmed_by IS NULL)
        OR (nea_report_days_confirmed_at IS NOT NULL AND nea_report_working_days IS NOT NULL))
);

COMMENT ON TABLE public.safety_settings IS
    'MES-7b-1:安全的设定(单行)。nea_report_working_days = V19,向 NEA 交书面报告的工作日数;引导 2、未确认(出处:仓库里那条义务的记录,不是执照原文 —— Q11)。期限照它算、照它标"未确认",V19 留在待补的值上直到有人对着执照确认。module.safety.edit 经 set_safety_settings 改。';
COMMENT ON COLUMN public.safety_settings.nea_report_working_days IS
    'V19(MES-0 §5.1):书面报告要在事故日之后的第几个工作日之前交到 NEA。空 = Not yet set(期限算不出来)。';
COMMENT ON COLUMN public.safety_settings.nea_report_days_source IS
    'V19 这个数从哪里来的 —— 页面照原样显示。引导值的出处是 docs/forward-queue.md:2402 那一条义务的记录。';
COMMENT ON COLUMN public.safety_settings.nea_report_days_confirmed_at IS
    'V19 被对着 NEA 执照确认的时刻;空 = 未确认 —— 期限照算,但标"未确认",V19 留在 /settings/pending-values 上。';

INSERT INTO public.safety_settings (id, nea_report_working_days, nea_report_days_source) VALUES
    (true, 2, 'Repository record of the NEA duty — docs/forward-queue.md:2402 ("立即通报 … 两个工作日内提交书面报告"); not yet confirmed against the NEA licence.');

CREATE TRIGGER trg_safety_settings_updated_at
    BEFORE UPDATE ON public.safety_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.safety_settings ENABLE ROW LEVEL SECURITY;
-- 读:安全查看码(事故页的设定面板、期限与待补的值那一行)。写只经函数。
CREATE POLICY "safety_settings select by permission" ON public.safety_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.safety.view'::text)));
GRANT SELECT ON public.safety_settings TO authenticated;
REVOKE ALL ON public.safety_settings FROM anon;
