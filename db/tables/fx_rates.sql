-- db/tables/fx_rates.sql
-- 行方外汇牌价,按日、按方向留档。FIN-0 重建(旧表是"一天一个数"的 rate_to_usd,
-- 且当时表里没有一行数据,直接拆了重建)。
--
-- 【语义】1 单位外币 = rate_sgd_per_unit 新元。币种对 = currency 兑 SGD(本位币);
-- SGD 自己永远没有行(CHECK 挡住)。
--
-- 【为什么一天不止一个数】银行买入与卖出不同价,该用哪一侧取决于交易方向:
--   tt_buy  = 银行买入我们手上的外币(收入、应收按它估值)
--   tt_sell = 银行把外币卖给我们(支出、应付按它估值)
--   mid     = 中间价(重估值等无方向口径)
-- source 记牌价出处(暂定 DBS;MAS 存档中间价可作补漏与核对,不作首选源)。
--
-- 【每天要录】(与 metal_prices 的每日录入同一套路)—— 历史牌价隔天可能就查不回来,
-- 当天没录的日子等于永远缺口。fx_rate_gaps 视图把"有外币交易却没牌价"的日子顶出来。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【存的牌价只用来"估值",永远不用来"算兑换"/ C4】
-- 真实的货币兑换(银行把 USD 换成 SGD)以银行水单上的【两边实际金额】入账,
-- 汇率只是两个实际数的商 —— 那条路(record_payment 跨币种分支)不查本表。
-- 本表服务的是【没有发生兑换】的交易:开一张 USD 发票、给 USD 余额重估值、
-- 给 USD 计价的进料入账。谁要是想"改进"成用牌价去折算兑换的另一边,请先读这段。
-- ════════════════════════════════════════════════════════════════════════════
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql;
--       rebuilt (rate types, source, SGD base) by
--       db/migrations/2026-08-04-fin0-sgd-base-and-fx-policy.sql.

CREATE TABLE public.fx_rates (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    currency          text NOT NULL REFERENCES public.currencies (code) CHECK (currency <> 'SGD'),
    rate_date         date NOT NULL,
    rate_type         text NOT NULL CHECK (rate_type IN ('tt_buy', 'tt_sell', 'mid')),
    rate_sgd_per_unit numeric NOT NULL CHECK (rate_sgd_per_unit > 0),
    source            text NOT NULL DEFAULT 'DBS',
    notes             text,
    deleted_at        timestamptz,
    created_by        uuid DEFAULT auth.uid(),   -- 谁录的 —— 牌价是手工日课,要能问到人
    updated_by        uuid DEFAULT auth.uid(),
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

-- 一币种、一天、一侧,只一条在册(软删的占不住位)
CREATE UNIQUE INDEX idx_fx_rates_one_per_day
    ON public.fx_rates (currency, rate_date, rate_type) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_fx_rates_updated_at
    BEFORE UPDATE ON public.fx_rates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.fx_rates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fx_rates select by permission"
    ON public.fx_rates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "fx_rates insert by permission"
    ON public.fx_rates
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "fx_rates update by permission"
    ON public.fx_rates
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "fx_rates delete by permission"
    ON public.fx_rates
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));

COMMENT ON TABLE public.fx_rates IS
    '行方每日外汇牌价(1 外币 = rate_sgd_per_unit SGD)。只用于估值【未发生兑换】的交易;真实兑换以银行实际金额入账,不查本表。';
COMMENT ON COLUMN public.fx_rates.rate_type IS
    'tt_buy = 银行买入外币(收入/应收);tt_sell = 银行卖出外币(支出/应付);mid = 中间价(重估值)。';
COMMENT ON COLUMN public.fx_rates.source IS
    '牌价出处,暂定 DBS。MAS 存档的日中间价可补漏与核对,不作首选源。';
