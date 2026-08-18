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
    -- LME-1a:这个数【是哪一种来源】。四取一,**没有默认值** ——
    -- 有默认值时任何漏填都会被悄悄补上一个看起来像答案的值;没有默认值,
    -- 漏填就是一次失败(实测:直插本表是走得通的,所以这道闸必须在表上)。
    source              text    NOT NULL
        CHECK (source IN ('published_index','broker_quote','internal_estimate','unknown')),
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
    price_index text REFERENCES public.metal_price_indices (code),
    -- ── LME-1a 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 争议时答得出来的两样东西。都可空,而【空就是一个答案】:没有记录过。
    source_reference text,
    quote_delayed    boolean,
    -- published_index 必须说得出【是哪一个】——"来自某个发布的指数、但不知道
    -- 是哪一个"是一句自相矛盾的话:LME 与 SMM 报价币种不同、换算路径不同。
    CONSTRAINT metal_prices_index_source_pairing
        CHECK (source <> 'published_index' OR price_index IS NOT NULL)
);

COMMENT ON COLUMN public.metal_prices.source IS 'LME-1a:这个数【是哪一种来源】。四取一,没有默认值 —— 漏填就是一次失败,而不是悄悄补上一个看起来像答案的值。
published_index=发布的指数行情(【是哪一个由 price_index 回答】,两列合起来才是完整出处,并由 metal_prices_index_source_pairing 强制配对);broker_quote=交易对手/经纪商报价;internal_estimate=我们自己的估计(它不是市场价,把它当市场价正是本列要防的事);unknown=没有记录过。
【unknown 是可表示的状态,不是默认值】新录入必须明说是哪一种;只有 LME-1a 之前的历史行携带它。
【本列此前是一句空话】text NOT NULL DEFAULT ''manual'' 且无 CHECK,而唯一的写入函数把它写死成 ''manual'' —— 于是它看起来在回答"从哪来",实际只回答了"有人打字进来的",而那对任何一条记录都成立。
【约束在表上,不只在函数里】实测:以 authenticated + module.pricing.edit 直插本表【成功】,source 悄悄落成默认值 —— upsert_metal_prices 不是唯一的门。';

COMMENT ON COLUMN public.metal_prices.source_reference IS 'LME-1a:这条行情的【凭据】—— 一份单据号、一个截图文件名、一封经纪商邮件的主题行。**自由文本是刻意的:它是证据,不是数据**,没有人会按它做聚合或判断,而任何结构化都会逼着录入的人把手里真实的那一样东西塞进一个不合身的格子里。
【空 = 没有记录过凭据】不是"没有凭据"。不推断、不给默认值。';

COMMENT ON COLUMN public.metal_prices.quote_delayed IS 'LME-1a:这个数是【当天的】还是【延迟/次日的】。true=延迟(例如 LME 免费的次日行情),false=当天,**NULL=没有记录过**——三种状态,不是两种。
【为什么要单独记】LME-0 勘察到:免费那一档是次日延迟的。一个次日的数用在当天成交的合同上,可能根本不合格;而"合不合格"这件事,事后只有这一列答得出来。
【不推断】不会从 source 或 price_date 猜它 —— 猜出来的合规判断比没有更坏。';

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
