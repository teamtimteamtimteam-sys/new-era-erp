-- METAL-3 第一部分(2026-08-11):SMM 按 CNY 报价 —— 换算在【读的时候】,按【报价那一天】的
--                      中间价,而"CNY"这件事被标成【房屋假设】,不是一条合同条款
--
-- Tim 的答复:quote_currency = CNY,结算按当天的汇率换。他同时说明:这是他认为
-- 合理的条款,【不是签下来的】—— 今天还没有任何一笔 SMM 交易。所以机制照建,
-- 但它必须写着"这是房屋假设",而不是装作系统已经知道合同怎么写。
-- 真的 SMM 合同出现时可能另有说法,代码不该读起来像是已经知道了。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【三件事,按报告的顺序】
--
-- 一 · 加一个币种不是装饰。currencies.code 上有 CHECK (code IN ('USD','SGD')),
--   放宽它是一次迁移(表注释早写着"加币种时同步放宽此 CHECK")。实测过它【不会】
--   带进来什么:界面上的币种下拉全是写死的 <option>(币种字面量检查里唯一豁免的
--   那种形状),getCurrencyCodes() 导出了却【无人调用】,所以 CNY 不会出现在任何
--   表单里;重估按 journal_lines 走而不是按币种表走,CNY 零过账即零影响;
--   看板的 fx_rate_gap 支同理。
--   【唯一的活隐患】lib/currencyMap.ts 的 bankAccountFor 对未知币种回退 '1010'
--   (美元账户)。今天没有任何路径把 CNY 送到那里,而 CNY 也【不可交易】——
--   这一条写在这里,是因为"顺手加一行"最容易漏掉的正是它。
--
-- 二 · 用【中间价 mid】,而且是【两条腿】。fx_rates 记的是 rate_sgd_per_unit
--   (本位币/单位外币),而本函数的输出基准是 USD,所以:
--       usd = cny × rate(CNY) / rate(USD)
--   两条腿都取【报价那一天】的 mid。用 mid 而不是 tt_buy/tt_sell:行情是参考价,
--   不是成交价 —— 把银行的买卖价差焊进一个市场事实里是错的。
--   代价是明写的:线上历史上只有【一行】mid(USD,2026-07-31),对 9 行 tt。
--   这一刀把 mid 从"存在的一种类型"变成"必须维护的一种类型",而且 USD 也一样。
--   所以它同时进了月结与全新安装清单,并且看板那一支现在也盯得住(见下)。
--
-- 三 · 换算在【读的时候】发生,报价按发布原样以 CNY 存。存成换好的 USD 会把
--   某一天的汇率焊进一条市场记录,并且丢掉原始数字 —— 汇率事后更正时它就是错的。
--
-- 【与 AGENTS.md 那句"本函数不换算"的关系:两种换算,不要混】
--   * 【输出】换算:USD → 单据币种,发生在【路径】上(computeLineEstimate),
--     用成交日的 tt_buy/tt_sell。那一句仍然成立,本刀一字未动。
--   * 【输入】换算:报价币种 → 本函数的 USD 基准,只能发生在函数里 ——
--     只有它知道自己挑中了哪一条报价、那条报价是哪一天的。
--   两次换算、两个日期、两种价:说清楚,免得下一个读者以为它们互相矛盾。
--
-- 【为什么是报价那一天,而不是今天、也不是结算日】报价是【那一天的】市场事实。
--   按今天的汇率换,同一条历史报价会随着你什么时候打开屏幕而值不同的钱 ——
--   那是在改写历史,正是 price_history 当初存在的理由。
--   均价口径同理:【每条报价各按自己那天换算,再取平均】,而不是先平均再换 ——
--   否则窗口内的一次汇率波动会污染窗口里的每一天。
--
-- 【缺行情 vs 缺汇率:两种缺,两种处置】缺行情仍然是跳过(FIN-15 的分工不变);
--   而【有报价、缺汇率】是拒绝(FX_RATE_MISSING|CNY|日期|mid)—— 我们手里有那个
--   数字,只是表达不出来,编一个汇率正是 THE FX RULE 不许的事,按零跳过则会把一条
--   真实发布的价格算成不值钱。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1 · 第三个币种 ──────────────────────────────────────────────────────────
ALTER TABLE public.currencies DROP CONSTRAINT currencies_code_check;
ALTER TABLE public.currencies ADD CONSTRAINT currencies_code_check
    CHECK (code IN ('USD','SGD','CNY'));
INSERT INTO public.currencies (code, name, is_base) VALUES ('CNY', 'Chinese Yuan', false);

-- ── 2 · 指数的报价币种,以及【这个币种是怎么定下来的】────────────────────────
ALTER TABLE public.metal_price_indices
    ADD COLUMN quote_currency_basis text
        CHECK (quote_currency_basis IN ('house_assumption','contract'));

COMMENT ON COLUMN public.metal_price_indices.quote_currency_basis IS
$$这个指数的 quote_currency 是【怎么定下来的】:'contract' = 有签下来的合同这么写;
'house_assumption' = 公司认为合理、但还没有任何一笔交易这么约定过。

为什么要有这一列:光写 quote_currency = 'CNY' 会读成"合同就是这么定的"。
Tim 给出 CNY 时明说了那是他认为合理的条款,而不是签下来的 —— 今天一笔 SMM 交易
都还没有。真的 SMM 合同出现时可能另有说法,而代码不该读起来像是已经知道了。
计价出处里一并记下当时是哪一种,于是【按假设算出来的那些数】日后与【按合同算出来的】
分得开。合同落地时改这一个字段,不需要动任何代码。$$;

UPDATE public.metal_price_indices
   SET quote_currency = 'CNY',
       quote_currency_basis = 'house_assumption',
       notes = 'SMM 以 CNY/吨发布。报价币种【CNY 是房屋假设,不是合同条款】—— Tim 认为按当天汇率换算是合理的做法,但今天还没有任何一笔 SMM 交易这么约定过(quote_currency_basis = house_assumption)。真的合同出现时可能另有说法,届时改这一行即可。换算发生在读的时候:按【报价那一天】的中间价,两条腿(CNY→本位币→USD)。'
 WHERE code = 'SMM';

UPDATE public.metal_price_indices
   SET quote_currency_basis = 'contract',
       notes = 'USD/吨是 LME 的市场惯例 —— 这一条是市场事实,不是某一笔合同的条款,所以按 contract(已确定)记,不是房屋假设。'
 WHERE code = 'LME';

ALTER TABLE public.metal_price_indices
    ADD CONSTRAINT metal_price_indices_currency_basis_shape
    CHECK (quote_currency IS NULL OR quote_currency_basis IS NOT NULL);

COMMIT;
