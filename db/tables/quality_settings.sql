-- db/tables/quality_settings.sql
-- MES-6a-1(2026-10-09,MES-0 §5.1 V16;MES-6a Step 0 Q14,Tim):【质量的设定 —— 单行】。今天只有一样:V16。
--   internal_retention_days —— 一份【没有合同天数撑着】的样品留多少天(取样日 + 这个数 = 它的 retain_until)。为空 = "Not yet set":
--     那样的样品建出来 retain_until 为空(屏幕上 Not yet set),不进 sample_retention_due 的提醒。
--     为空、而且有一份还没处置、没有合同天数的样品时,/settings/pending-values 上 V16 那一行出现(module.quality.view)。
--   ★ 改它【不】回头改已有的样品 —— retain_until 在建的那一刻抄下(Q8)。
--   由 module.quality.edit 经 set_quality_settings 改;修改史在变更记录里(主语 quality_settings,画在 /quality/samples)。
--   RUNTIME CONFIG:引导一行、天数为空;Tim 填一次,线上就与本文件不同 —— 那是系统在正常工作(electricity_settings 的先例)。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.quality_settings (
    id                      boolean PRIMARY KEY DEFAULT true CHECK (id),
    internal_retention_days integer CHECK (internal_retention_days IS NULL OR internal_retention_days > 0),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    updated_by              uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.quality_settings IS
    'MES-6a-1:质量的设定(单行)。internal_retention_days = V16,没有合同天数的样品留多少天;为空时那样的样品 retain_until 为空(Not yet set)。改它不回头改已有的样品。module.quality.edit 经 set_quality_settings 改。';
COMMENT ON COLUMN public.quality_settings.internal_retention_days IS
    'V16(MES-0 §5.1):没有合同天数的样品留多少天。空 = Not yet set。由 Tim / 质量在第一份要留的样品时给。';

INSERT INTO public.quality_settings (id) VALUES (true);

CREATE TRIGGER trg_quality_settings_updated_at
    BEFORE UPDATE ON public.quality_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.quality_settings ENABLE ROW LEVEL SECURITY;
-- 读:质量查看码(样品页的设定面板与待补的值那一行)。写只经函数。
CREATE POLICY "quality_settings select by permission" ON public.quality_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.quality.view'::text));
GRANT SELECT ON public.quality_settings TO authenticated;
REVOKE ALL ON public.quality_settings FROM anon;
