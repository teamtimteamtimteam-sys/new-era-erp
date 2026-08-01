-- db/tables/finance_settings.sql
-- Single-row finance settings. locked_before is the period lock: journal
-- entries dated before it are rejected by post_journal_entry (PERIOD_LOCKED).
-- The boolean-true PK enforces the single row.
--
-- GST 三列:公司尚未做 GST 登记,先把字段建好,让"登记"变成改设置而不是改表结构
-- (税金分录本身留给后续切次,见 cut 2a 迁移头注释)。
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql;
-- gst_registered / gst_rate_pct / gst_registration_no added by
-- db/migrations/2026-07-31-phase4-cut2a-invoices.sql —— 该切次【漏了同步本镜像】,
-- 2026-07-31 的镜像漂移审计发现后补正(同 journal_entries.sql 的 source_type 一课:
-- 动表的迁移必须在同一提交里更新镜像)。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.finance_settings (
    id                  boolean PRIMARY KEY DEFAULT true CHECK (id),  -- 单行表:PK 恒为 true
    locked_before       date,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid DEFAULT auth.uid(),
    gst_registered      boolean NOT NULL DEFAULT false,
    gst_rate_pct        numeric NOT NULL DEFAULT 0
                        CHECK (gst_rate_pct >= 0 AND gst_rate_pct <= 100),
    gst_registration_no text
);

INSERT INTO public.finance_settings (id, locked_before) VALUES (true, NULL);

CREATE TRIGGER trg_finance_settings_updated_at
    BEFORE UPDATE ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.finance_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "finance_settings select by permission"
    ON public.finance_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "finance_settings insert by permission"
    ON public.finance_settings
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "finance_settings update by permission"
    ON public.finance_settings
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "finance_settings delete by permission"
    ON public.finance_settings
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));
