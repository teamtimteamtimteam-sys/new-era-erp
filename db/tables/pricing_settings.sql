-- db/tables/pricing_settings.sql
-- 计价模块的可配置门槛。单行配置表(与 finance_settings / hr_settings 同形)。
--
-- NOTE: introduced by db/migrations/2026-08-11-metal1-price-anomaly-warning.sql.
-- First-run script (plain CREATEs).

-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- 写入策略特意开在 module.pricing.edit 上:改阈值与录行情是同一件工作,同一个码。
-- 读给所有登录用户 —— 阈值不是秘密,录入页要把它显示在提示里。
-- 所以【线上与本文件不一致是正常的,不是漂移】,check_mirrors.py 不把本表与线上
-- 逐行比对(它只保证这一套镜像自己首尾相顾)。
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE public.pricing_settings (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    -- 【故意没有 DEFAULT】看得见的默认值 = 下面引导里那一行;schema 默认值是
    -- 看不见的那一种(FIN-35/FIN-36 的判别法)。重建时必须显式带着这个值。
    metal_price_change_warn_pct numeric NOT NULL
        CHECK (metal_price_change_warn_pct > 0),
    notes text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid DEFAULT auth.uid(),
    -- ── METAL-2 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 分摊、销售的现货预设、库存页估值 —— 这三条路径【没有合同可以继承指数】。
    -- 【它是一个默认值在替一条缺席的条款站位,不是正确答案】:分摊出来的成本不是
    -- "按 LME 结算"的,它是"在没有条款可循时按房屋约定取了价"。
    -- NULL = 沿用未标注指数的老序列(与 METAL-2 之前的行为完全一致)。
    default_metal_index text REFERENCES public.metal_price_indices (code),
    -- ── EXEC-1a 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 行情多少天没更新算【旧】。看板的 metal_quote_stale 支现读这一列 ——
    -- 没有任何地方写死这个数(与同表的 metal_price_change_warn_pct 同一条理由:
    -- 一个谁也看不见的默认值等于替所有人做了这个判断)。
    metal_quote_stale_days integer NOT NULL DEFAULT 14
        CHECK (metal_quote_stale_days > 0)
);

CREATE TRIGGER trg_pricing_settings_updated_at
    BEFORE UPDATE ON public.pricing_settings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.pricing_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "pricing_settings select"
    ON public.pricing_settings AS PERMISSIVE FOR SELECT TO authenticated USING (true);

CREATE POLICY "pricing_settings update by permission"
    ON public.pricing_settings AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.pricing.edit'))
    WITH CHECK (has_permission('module.pricing.edit'));

-- ── 引导 ────────────────────────────────────────────────────────────────────
-- 【50 是默认值,不是决定】证据(线上实测,2026-08-11):真实的相邻报价变动是
-- co 32,000→30,000(−6.25%)、ni 16,000→15,000(−6.25%);而 2026-07-30 那次
-- 异常是 24,000→80,000(+233%)与 80,000→20,000(−75%)。50 把两类分得很开。
-- 金属市场的真实波动幅度是 Tim 的判断,不是这一行的 —— 改它不需要改代码。
INSERT INTO public.pricing_settings (id, metal_price_change_warn_pct, notes)
VALUES (true, 50,
    '默认值,不是决定:线上真实相邻变动 ≤6.25%,而 2026-07-30 那次异常是 +233% / −75%。改这一行不需要改代码。');

COMMENT ON COLUMN public.pricing_settings.default_metal_index IS
    'METAL-2:分摊、现货预设、库存估值这三条【没有合同】的路径取哪条序列的价。它替一条缺席的条款站位,不是"这些数字按某个声明的指数结算了"。NULL = 沿用未标注指数的老序列。';

COMMENT ON COLUMN public.pricing_settings.metal_quote_stale_days IS
    '行情多少天没更新算【旧】(EXEC-1a,ASY-3 报告为它留的那一列)。看板的 metal_quote_stale 支现读这一列 —— 【没有任何地方写死这个数】。默认 14:实测录入节奏是"六周两次",7 天会天天响(等于没有警报),30 天要等到 average 口径已经跳过那个金属之后才响。判据按 price_date 不按 created_at —— 补录发生过(6-25 的行情 7-2 才录进来),按 created_at 会让补录当天显得刚刚更新过。';
