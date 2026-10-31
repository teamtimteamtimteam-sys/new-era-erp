-- db/tables/esg_settings.sql
-- ESG-2(Tim 2026-10-31 Q4 · Q9):【ESG 的设定 —— 单行】。今天只有一样:
--   standard_hours_per_day —— 一个工作日算几个小时,用来把考勤折成「工时」(安全率页的分母:LTIFR = 误工事故 × 1,000,000 ÷ 工时)。
--     为空 = 「没设」:安全率页每个月的工时读「没设标准日工时」,一个率都不算(不猜一个 8)。Tim 设一次(他的待办)。
--   由 action.manage_esg(admin · cco · cfo)经 esg_set_standard_hours 改;修改史在变更记录里(主语 esg_settings)。
--   RUNTIME CONFIG:引导一行、值为空;Tim 填一次,线上就与本文件不同 —— 那是系统在正常工作。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.esg_settings (
    id                      boolean PRIMARY KEY DEFAULT true CHECK (id),
    standard_hours_per_day  numeric CHECK (standard_hours_per_day IS NULL OR (standard_hours_per_day > 0 AND standard_hours_per_day <= 24)),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    updated_by              uuid DEFAULT auth.uid()
);
COMMENT ON TABLE public.esg_settings IS
    'ESG-2:ESG 的设定(单行)。standard_hours_per_day = 一个工作日算几个小时(安全率的工时分母);为空时不算任何率。action.manage_esg 经 esg_set_standard_hours 改。';
COMMENT ON COLUMN public.esg_settings.standard_hours_per_day IS
    '一个工作日算几个小时(Tim 2026-10-31 Q4)。工时 = (在职期间的工作日 − 批准的请假天数)× 本值 + 三列加班工时。空 = 没设 —— 安全率页不算率。';
INSERT INTO public.esg_settings (id) VALUES (true);
CREATE TRIGGER trg_esg_settings_updated_at
    BEFORE UPDATE ON public.esg_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
ALTER TABLE public.esg_settings ENABLE ROW LEVEL SECURITY;
-- 读:安全查看码(安全率页)或维护它的码。写只经函数。
CREATE POLICY "esg_settings select by permission" ON public.esg_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_any_permission(ARRAY['module.safety.view'::text, 'action.manage_esg'::text])));
REVOKE ALL ON public.esg_settings FROM authenticated, anon;
GRANT SELECT ON public.esg_settings TO authenticated;
