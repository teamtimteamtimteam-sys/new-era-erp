-- 50 以外币发布的行情:按【报价那一天】的中间价换算,原始数字按发布原样存
--
-- 【A 臂:换算用的是报价那一天,不是今天,也不是结算日】报价是【那一天的】市场
-- 事实。按今天的汇率换,同一条历史报价会随着你什么时候打开屏幕而值不同的钱 ——
-- 那是在改写历史,正是 price_history 当初存在的理由。本臂给两天不同的汇率,
-- 于是"按报价日换"与"按参考日换"给出不同的数;取错日子过不了。
--
-- 【B 臂:均价是【每条各按自己那天换】,再平均 —— 不是先平均再换】
-- 窗口里两天的汇率不同,两种算法给出不同的数(手算见臂内)。先平均再换会让
-- 窗口内的一次汇率波动污染窗口里的每一天。
--
-- 【C 臂:缺汇率是【拒绝】,不是跳过】缺行情跳过(FIN-15 的分工不变),而
-- 有报价、缺汇率是另一件事:我们手里有那个数字,只是表达不出来。编一个汇率是
-- THE FX RULE 不许的,按零跳过则把一条真实发布的价格算成不值钱。
--
-- 【D 臂:原始数字按发布原样存,出处能把 USD 数重导出】存成换好的 USD 会把某一天
-- 的汇率焊进一条市场记录,并丢掉原始数字 —— 汇率事后更正时它就是错的。
-- 本臂从 fx_legs 里把 CNY 原始数与两条腿的汇率取出来,自己乘一遍,与函数给的
-- USD 数对上(与 FIN-26 "一条算出来的行要能被重新导出"同一条)。
--
-- 【E 臂:CNY 是【房屋假设】,这件事必须在数据里分得开】quote_currency_basis
-- 记着它是 house_assumption 还是 contract。光写 CNY 会读成"合同就是这么定的",
-- 而 Tim 明说那是他认为合理的做法、今天一笔 SMM 交易都还没有。
--
-- 【F 臂:缺的中间价要出现在【等人处理】那一头】fx_rate_gaps 原来的日期来源只有
-- 过账,而 CNY 永远不会过账(它不可交易)—— 于是缺一条 CNY 中间价只会在有人计价时
-- 以一次拒绝现身。现在报价日也是一个来源,只问 mid。
--
-- 日期全部落在 2027,自带数据(README 第 4/5 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_terms jsonb; v_calc jsonb; v_leg jsonb; v_legs jsonb;
    v_spot numeric; v_avg numeric; v_naive numeric;
    v_msg text; v_denied boolean; v_n int;
    v_basis text;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    UPDATE pricing_settings SET metal_price_change_warn_pct = 500 WHERE id;  -- 本 fixture 不测异常提示
    UPDATE metal_prices SET deleted_at = now() WHERE deleted_at IS NULL;
    -- 前提显式设定:本 fixture 自己摆汇率,不继承线上任何一天
    DELETE FROM fx_rates WHERE rate_date BETWEEN '2027-06-01' AND '2027-06-30';

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-50', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.pricing.view','module.pricing.edit','module.finance.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 两天的行情与【不同的】汇率。判别力全在"两天不一样"这件事上。
    --   6-10:CNY 0.20 / USD 1.25  → 因子 0.16
    --   6-11:CNY 0.30 / USD 1.20  → 因子 0.25
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit) VALUES
        ('CNY', '2027-06-10', 'mid', 0.20), ('USD', '2027-06-10', 'mid', 1.25),
        ('CNY', '2027-06-11', 'mid', 0.30), ('USD', '2027-06-11', 'mid', 1.20),
        -- 6-12(周六)也放一组【明显不同】的汇率:它是 A 臂第三问的判别力所在 ——
        -- 那天没有报价,所以 spot 取 6-11 那条,而参考日是 6-12。两个日子的汇率
        -- 必须不同,"按报价日换"与"按参考日换"才会给出不同的数。
        ('CNY', '2027-06-12', 'mid', 0.40), ('USD', '2027-06-12', 'mid', 1.00);
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index) VALUES
        ('cu', 100000, '2027-06-10', 'SMM'),
        ('cu', 100000, '2027-06-11', 'SMM');

    v_terms := jsonb_build_object('price_index','SMM','price_basis','spot','average_days',NULL,
        'treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,
        'payables', jsonb_build_object('cu',100));

    -- ══════════ A. 按【报价那一天】换,不是按参考日 ══════════════════════════
    -- 参考日 6-11,挑中的报价就是 6-11 那条 → 因子 0.25 → 100000×0.25/1000 = 25 USD/kg
    v_calc := calculate_metal_price_from_terms(v_terms,
        jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-06-11');
    v_spot := (v_calc->>'unit_price_usd_per_kg')::numeric;
    IF v_spot <> 25 THEN
        RAISE EXCEPTION 'FIXTURE 50A 失败:6-11 的报价按 6-11 的中间价换应得 25 USD/kg,实得 %', v_spot;
    END IF;
    -- 参考日 6-10:挑中 6-10 那条 → 因子 0.16 → 16 USD/kg。
    -- 【若实现按"今天/参考日"以外的某一天换,这两个数会相等或都不对】
    v_calc := calculate_metal_price_from_terms(v_terms,
        jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-06-10');
    v_spot := (v_calc->>'unit_price_usd_per_kg')::numeric;
    IF v_spot <> 16 THEN
        RAISE EXCEPTION 'FIXTURE 50A 失败:6-10 的报价按 6-10 的中间价换应得 16 USD/kg,实得 % —— 同一条 100,000 CNY 的报价在两天给出不同的 USD,正是"按报价自己那天换"的意思;两天算出同一个数说明换算取错了日子',
            v_spot;
    END IF;

    -- 【判别力真正在这一问】参考日 6-12(周六,当天没有报价)→ spot 取 6-11 那条
    -- 报价,而它必须按【6-11】的汇率换(因子 0.25 → 25),不是按参考日 6-12 的
    -- 汇率(因子 0.40 → 40)。
    -- 【第一版没有这一问,所以它测不到自己要测的规则】:前两问里参考日恰好就是
    -- 报价日,把换算改成"按参考日"照样全绿 —— 故障注入当场证明了这一点。
    -- 一条在缺陷下依然通过的断言,不是断言。
    v_terms := jsonb_build_object('price_index','SMM','price_basis','spot','average_days',NULL,
        'treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,
        'payables', jsonb_build_object('cu',100));
    v_calc := calculate_metal_price_from_terms(v_terms,
        jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-06-12');
    v_spot := (v_calc->>'unit_price_usd_per_kg')::numeric;
    IF v_spot <> 25 THEN
        RAISE EXCEPTION 'FIXTURE 50A 失败:参考日 6-12 取到的是 6-11 那条报价,它必须按【6-11】的中间价换(25 USD/kg),实得 % —— 40 说明它按【参考日】的汇率换了,那是拿今天的汇率去重估一条历史行情,同一条报价会随着你什么时候打开屏幕而值不同的钱',
            v_spot;
    END IF;
    IF (v_calc->'lines'->0->'fx_legs'->0->>'quote_date') <> '2027-06-11' THEN
        RAISE EXCEPTION 'FIXTURE 50A 失败:出处里的 quote_date 应当是报价自己那天(2027-06-11),实得 %',
            v_calc->'lines'->0->'fx_legs'->0->>'quote_date';
    END IF;

    -- ══════════ B. 均价:每条各按自己那天换,再平均 ══════════════════════════
    -- 正确:(16 + 25) / 2 = 20.5 USD/kg
    -- 错误(先平均再换,按参考日 6-11 的因子):100000 × 0.25 / 1000 = 25
    v_terms := jsonb_build_object('price_index','SMM','price_basis','average','average_days',5,
        'treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,
        'payables', jsonb_build_object('cu',100));
    v_calc := calculate_metal_price_from_terms(v_terms,
        jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-06-11');
    v_avg := (v_calc->>'unit_price_usd_per_kg')::numeric;
    IF v_avg <> 20.5 THEN
        RAISE EXCEPTION 'FIXTURE 50B 失败:窗口内两条各按自己那天换再平均应得 20.5 USD/kg,实得 % —— 25 说明它先平均了 CNY 再按一个日子换,那样窗口内的一次汇率波动会污染窗口里的每一天',
            v_avg;
    END IF;
    -- 出处逐条记下(两条腿都在),否则这个均价没法被重导出
    v_legs := v_calc->'lines'->0->'fx_legs';
    IF jsonb_array_length(v_legs) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 50B 失败:均价的出处应逐条记(2 条),实得 % —— 只记一条就等于说"这个均价按某一天换的",而它不是',
            jsonb_array_length(v_legs);
    END IF;

    -- ══════════ C. 有报价、缺汇率 → 拒绝(不是跳过、不是按零)═════════════════
    -- 【日子选在 6-25(周五、工作日)而不是 6-12】6-12 是周六 —— 那一天没有牌价是
    -- 【正常的】,fx_rate_asof 会合法地就近取周五的价,于是不会拒绝。第一版就写在
    -- 6-12,这一臂因此测不到它想测的东西(拒绝没发生,而那是对的)。
    -- 6-25 距最近一条汇率 14 天,远超 4 天硬上限,无论周末与否都必然拒绝。
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index)
    VALUES ('ni', 90000, '2027-06-25', 'SMM');
    v_terms := jsonb_build_object('price_index','SMM','price_basis','spot','average_days',NULL,
        'treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,
        'payables', jsonb_build_object('ni',100));
    v_denied := false;
    BEGIN
        v_calc := calculate_metal_price_from_terms(v_terms,
            jsonb_build_array(jsonb_build_object('metal','ni','content_pct',100)), 1000, DATE '2027-06-25');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'FX_RATE_MISSING|CNY|2027-06-25|mid%' THEN
        RAISE EXCEPTION 'FIXTURE 50C 失败:有报价而缺当日中间价应【点名拒绝】,实得 denied=% msg=% —— 跳过会把一条真实发布的价格算成不值钱,而编一个汇率是 THE FX RULE 不许的',
            v_denied, COALESCE(v_msg, '(算出来了)');
    END IF;

    -- ══════════ D. 原始数字按发布原样存,USD 数能从出处重导出 ═════════════════
    IF (SELECT price_usd_per_tonne FROM metal_prices
         WHERE metal='cu' AND price_date='2027-06-11' AND price_index='SMM') <> 100000 THEN
        RAISE EXCEPTION 'FIXTURE 50D 失败:表里存的应当是【发布时的 CNY 原数】100000 —— 存成换好的 USD 会把某一天的汇率焊进一条市场记录,并丢掉原始数字';
    END IF;
    v_terms := jsonb_build_object('price_index','SMM','price_basis','spot','average_days',NULL,
        'treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,
        'payables', jsonb_build_object('cu',100));
    v_calc := calculate_metal_price_from_terms(v_terms,
        jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-06-11');
    v_leg := v_calc->'lines'->0->'fx_legs'->0;
    IF round((v_leg->>'original_price')::numeric * (v_leg->>'rate_quote_ccy')::numeric
             / (v_leg->>'rate_usd')::numeric, 6) <> (v_leg->>'usd_per_tonne')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 50D 失败:出处里的原始数与两条腿汇率应当能把 USD 数【重新算出来】,实得 % —— 记了却导不出,等于要人相信它',
            v_leg::text;
    END IF;
    IF (v_leg->>'rate_type') <> 'mid' THEN
        RAISE EXCEPTION 'FIXTURE 50D 失败:行情换算应当用中间价(mid),实得 % —— 行情是参考价不是成交价,把银行买卖价差焊进一个市场事实里是错的',
            v_leg->>'rate_type';
    END IF;

    -- ══════════ E. CNY 是【房屋假设】,不是合同条款 ═════════════════════════
    SELECT quote_currency_basis INTO v_basis FROM metal_price_indices WHERE code = 'SMM';
    IF v_basis <> 'house_assumption' THEN
        RAISE EXCEPTION 'FIXTURE 50E 失败:SMM 的报价币种是 Tim 认为合理的做法,不是签下来的条款,应记 house_assumption,实得 % —— 光写 CNY 会读成"合同就是这么定的",而今天一笔 SMM 交易都还没有',
            COALESCE(v_basis, '(空)');
    END IF;
    -- 声明了币种就必须说清它是怎么来的(约束挡着,不是靠自觉)
    v_denied := false;
    BEGIN
        UPDATE metal_price_indices SET quote_currency_basis = NULL WHERE code = 'SMM';
    EXCEPTION WHEN check_violation THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 50E 失败:有 quote_currency 却没有 basis 应被约束挡住 —— 否则"这个币种是怎么定的"会悄悄变回没人回答的状态';
    END IF;

    -- ══════════ F. 缺的中间价出现在【等人处理】那一头 ════════════════════════
    -- 6-25 有 SMM 报价、没有 CNY 中间价 → 缺牌价视图应当报它,且只问 mid
    SELECT count(*) INTO v_n FROM fx_rate_gaps
     WHERE currency = 'CNY' AND rate_date = '2027-06-25'
       AND missing_types = ARRAY['mid']::text[] AND gap_source = 'quote';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 50F 失败:有报价而缺当日中间价的那一天应当出现在 fx_rate_gaps(来源 quote、只缺 mid),实得 % 行 —— CNY 永远不会过账,只按过账取日期就永远看不见它,于是缺中间价只会以一次计价拒绝现身,那是错的一头',
            v_n;
    END IF;
    -- 而【过账】来源仍然要三种价都问(原有行为没被这次改动削掉)
    IF EXISTS (SELECT 1 FROM fx_rate_gaps WHERE gap_source = 'posting'
                AND NOT (missing_types <@ ARRAY['tt_buy','tt_sell','mid']::text[])) THEN
        RAISE EXCEPTION 'FIXTURE 50F 失败:过账来源的缺价种类应仍在三种之内';
    END IF;
END $$;
ROLLBACK;
