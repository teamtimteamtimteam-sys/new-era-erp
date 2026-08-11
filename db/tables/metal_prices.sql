-- db/tables/metal_prices.sql
-- Metal prices (USD per tonne) — table + updated_at trigger + RLS.
-- Manual entry for now; a future LME feed only changes the `source` and the data
-- pipeline, not this shape. allocate_processing_costs() picks the most recent row
-- (deleted_at IS NULL) with price_date <= run.process_date for each metal.
-- Conventions match existing tables:
--   * soft delete via deleted_at
--   * audit fields created_by/updated_by, created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access
--   * Shared metal set with inbound/output_batch_metals; when adding a metal, widen ALL those CHECKs together.
--
-- NOTE: introduced by db/migrations/2026-07-02-phase1-cut2-cost-metal-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

-- 1. Table
CREATE TABLE public.metal_prices (
    id                  uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
    metal               text    NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    price_usd_per_tonne numeric NOT NULL CHECK (price_usd_per_tonne > 0),
    price_date          date    NOT NULL,
    source              text    NOT NULL DEFAULT 'manual',
    notes               text,
    deleted_at          timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    -- At most one price per metal per day (soft-deleted rows still occupy the slot;
    -- correct a price by updating the row, not inserting a duplicate).
    UNIQUE (metal, price_date),
    -- ── METAL-1 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 录入那一刻与【上一条报价】比出来的判词。三种:outside / inside /
    -- no_reference(这个金属还没有别的报价可比 —— 线上 7 个金属里有 4 个是这样,
    -- 而键错的第一条报价一样是错的,所以它不是 false)。
    -- 【为什么记在行上而不是只在界面上说】写入有三条路径(单条新增、批量录入、
    -- 编辑),只长在界面上的检查会被另外两条绕过;而且"上一条"会随着后来的报价
    -- 改变,事后重算给出的是另一个答案 —— 与 FIN-26 的 price_source 同一条论证:
    -- 记录,不推断。由 trg_metal_prices_anomaly 在写入前算一次。
    anomaly_check jsonb
);

COMMENT ON COLUMN public.metal_prices.anomaly_check IS
    'METAL-1:录入那一刻与【上一条报价】比出来的判词(outside / inside / no_reference)。记录,不事后推断 —— 后来的报价会改变"上一条"是什么。';

-- 2. BEFORE UPDATE trigger -> reuse the existing shared update_updated_at() (do NOT redefine it)
CREATE TRIGGER trg_metal_prices_updated_at
    BEFORE UPDATE ON public.metal_prices
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- 2b. METAL-1:异常判词。【永不拒】—— 3 倍的真实行情是可能的,而系统分不出
-- 哪一种是哪一种(与证书处置按类型分同一条理由)。触发器只把判词记下来,
-- 提醒由界面在【录入之前】给出,人确认后照常保存。
-- 阈值在 pricing_settings 里,看得见、改得动,不在代码里。
CREATE TRIGGER trg_metal_prices_anomaly
    BEFORE INSERT OR UPDATE ON public.metal_prices
    FOR EACH ROW
    EXECUTE FUNCTION trg_metal_price_anomaly();

-- 3. RLS: authenticated-only full access
ALTER TABLE public.metal_prices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "metal_prices select by permission"
    ON public.metal_prices
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

CREATE POLICY "metal_prices insert by permission"
    ON public.metal_prices
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.pricing.edit'::text));

CREATE POLICY "metal_prices update by permission"
    ON public.metal_prices
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.pricing.edit'::text)) WITH CHECK (has_permission('module.pricing.edit'::text));

CREATE POLICY "metal_prices delete by permission"
    ON public.metal_prices
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.pricing.edit'::text));
