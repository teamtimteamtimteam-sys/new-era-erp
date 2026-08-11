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
    -- 【一个金属、一天、一个指数,最多一条价】(软删的行仍占着位置;改价要 UPDATE
    -- 那一行,不是再插一条)。
    -- METAL-2:【NULLS NOT DISTINCT 不是花招,是为了保住这条老规矩】——
    -- PostgreSQL 默认把 NULL 视为互不相同,于是 (metal, price_date, price_index)
    -- 这个键会【恰好在 price_index 为空的那些行上失效】,而那是既有 11 行全部所在
    -- 的位置:同一个金属同一天可以插进两条未标注指数的价。NULLS NOT DISTINCT
    -- (PG15+,线上 17.6)让空值彼此相等,老规矩因此在老数据上继续成立。
    CONSTRAINT metal_prices_metal_price_date_index_key
        UNIQUE NULLS NOT DISTINCT (metal, price_date, price_index),
    -- ── METAL-1 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 录入那一刻与【上一条报价】比出来的判词。三种:outside / inside /
    -- no_reference(这个金属还没有别的报价可比 —— 线上 7 个金属里有 4 个是这样,
    -- 而键错的第一条报价一样是错的,所以它不是 false)。
    -- 【为什么记在行上而不是只在界面上说】写入有三条路径(单条新增、批量录入、
    -- 编辑),只长在界面上的检查会被另外两条绕过;而且"上一条"会随着后来的报价
    -- 改变,事后重算给出的是另一个答案 —— 与 FIN-26 的 price_source 同一条论证:
    -- 记录,不推断。由 trg_metal_prices_anomaly 在写入前算一次。
    anomaly_check jsonb,
    -- ── METAL-2 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 这条报价来自哪个市场。【NULL = 未声明指数】—— 既有 11 行都是这样,因为录入
    -- 时没有人选过,而指派一个就是替它宣称出处(与给那条 80,000 编个数字同罪)。
    -- 声明了指数的条款【看不见】这些行,反之亦然(IS NOT DISTINCT FROM)。
    -- 与 source 是两个轴:source 说"怎么来的",这一列说"哪个市场"。
    price_index text REFERENCES public.metal_price_indices (code)
);

COMMENT ON COLUMN public.metal_prices.price_index IS
    'METAL-2:这条报价来自哪个市场。【NULL = 未声明指数】—— 既有 11 行都是这样,因为录入时没有人选过,而指派一个就是替它宣称出处。声明了指数的条款看不见这些行,反之亦然。与 source(这个数字怎么来的)是两个轴。';

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
