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


-- ════════════════════════════════════════════════════════════════════════════
-- FX-RATES-1(2026-08-27):**改与删必须经函数,留痕。**
-- 改一条牌价 → record_fx_rate(带理由,写一行 'corrected' 史,连旧值一起记);
-- 撤销一条   → withdraw_fx_rate(软删 + 必填理由 + 一行 'withdrawn' 史)。
--
-- 【拦【改】与【删】,放行【建】—— 照抄 guard_inbound_price_change 的先例】
-- 那个守卫的抬头写着「INSERT 带价仍允许 —— 建单定价是正常路径」。同理:
-- 毁掉审计线索的是【改】与【删】,不是【建】—— 新建的那一行自己就是记录。
-- 而且拦 INSERT 会当场拦错东西:26 份 fixture 直接 INSERT 播种牌价,
-- 其中 09-fx-reach-back-bounded 播的是一个【未来】日期(用来测有界回溯),
-- 而 record_fx_rate 正确地拒绝未来日期。
--
-- 【UPDATE 只在【金额真的变了】时才拦】与先例逐字同形。改 deleted_at、
-- 改 notes、改 source 都不是"把一个数悄悄换掉",不该被这条闸挡住。
-- 【DELETE 一律要 ctx】硬删是这张表上唯一真正不可追的操作;触发器对超级用户
-- 同样生效,所以这扇门从此关上。
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.guard_fx_rate_write()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 【硬删:一律经函数】硬删不留任何痕迹,是这张表上唯一真正不可追的操作。
    IF TG_OP = 'DELETE' THEN
        IF NULLIF(current_setting('evoltrya.fx_ctx', true), '') IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_VIA_FUNCTION|DELETE';
        END IF;
        RETURN OLD;
    END IF;
    -- 【UPDATE:只拦【金额被改】那一种】—— 与 guard_inbound_price_change 逐字同形
    -- (它也只在 unit_price 真的变了时才拦)。改 deleted_at(撤销)、改 notes、
    -- 改 source 都不是"把一个数悄悄换掉",不该被这条闸挡住。
    IF NEW.rate_sgd_per_unit IS DISTINCT FROM OLD.rate_sgd_per_unit
       AND NULLIF(current_setting('evoltrya.fx_ctx', true), '') IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_VIA_FUNCTION|UPDATE';
    END IF;
    RETURN NEW;
END;
$fn$;

-- INSERT 不在此列 —— 理由见上(price_ctx 先例:建是正常路径,改与删才毁线索)。
CREATE TRIGGER trg_fx_rates_write_guard
    BEFORE UPDATE OR DELETE ON public.fx_rates
    FOR EACH ROW EXECUTE FUNCTION public.guard_fx_rate_write();
