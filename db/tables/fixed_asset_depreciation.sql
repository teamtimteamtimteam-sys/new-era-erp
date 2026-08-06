-- db/tables/fixed_asset_depreciation.sql
-- 月度折旧计提行(FIN-22)。一行 = 一次计提对一个资产;累计折旧 = Σ amount_base ——
-- 消耗是【记录的】,不是推导的(derived-vs-recorded)。幂等靠算术:
-- 目标累计 − Σ 已提 = 应提,同期第二次跑差额为 0,什么都不写。
-- 写入只经 depreciate_fixed_assets(SECURITY DEFINER);无 INSERT/UPDATE 策略。
--
-- NOTE: introduced by db/migrations/2026-08-06-fin22-fixed-assets-and-depreciation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.fixed_asset_depreciation (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id         uuid NOT NULL REFERENCES public.fixed_assets (id) ON DELETE RESTRICT,
    period_end       date NOT NULL,
    amount_base      numeric NOT NULL CHECK (amount_base > 0),
    journal_entry_id uuid NOT NULL REFERENCES public.journal_entries (id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid
);

COMMENT ON TABLE public.fixed_asset_depreciation IS
    '月度折旧计提行(FIN-22)。累计折旧 = Σ amount_base —— 消耗是【记录的】,不是推导的(AGENTS.md derived-vs-recorded)。幂等靠算术:目标累计 − Σ 已提 = 应提,同期第二次跑差额为 0。';

CREATE INDEX idx_fa_depreciation_asset ON public.fixed_asset_depreciation (asset_id);

ALTER TABLE public.fixed_asset_depreciation ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fa_depreciation select by permission" ON public.fixed_asset_depreciation
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
