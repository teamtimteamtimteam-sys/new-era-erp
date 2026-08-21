-- 49 LME 与 SMM 是两条序列:条款挑一条,而【挑错了要说出来,不是按零算】
--
-- 【本 fixture 存在的理由,一句话】两条序列之后,"没有行情"多出一种含义,
-- 而且是更坏的那一种:**这个金属在【合同约定的那个指数】上没有行情,
-- 而另一个指数上正躺着一条完全好用的数字**。旧的处置是跳过、计零 ——
-- 于是那个金属会被算成一文不值,正确答案就在隔壁一行。A/B 两臂钉的就是这件事。
--
-- 【C 臂:声明了指数的条款【看不见】未标注指数的行情】反过来也一样。让 LME 的单子
-- 去用一条未标注的报价,等于系统替那条报价宣称了出处 —— 与给那条 80,000 编一个
-- 数字是同一种伪造,只是晚一步发生。既有 11 行都在未标注那条序列上,所以这一臂
-- 同时也是"老公式今天照常工作"的回归断言。
--
-- 【D 臂:指数是条款,承诺之后不随公式改动】FIN-27 的形状,换一个字段再钉一次:
-- 抄下来的那份说 LME,公式事后改成 SMM,已成交的那一单仍按 LME 结算。
--
-- 【E 臂:报价币种未声明的指数【算不出钱】】它测的是【机制】:没声明报价币种就
-- 不许算钱,而不是"SMM 恰好没声明"。所以这一臂【自己建一个没声明币种的指数】——
-- 第一版直接拿 SMM 当例子,METAL-3 里 Tim 回答了(CNY / 房屋假设),那一臂当场变红,
-- 而断言本身没有错:错在把一个【会被人回答的业务决定】当成了固定前提。
-- 【这一臂是有历史的】METAL-2 主迁移里这道闸门写在"读出指数"那一行【之前】,
-- 于是它读到的 v_index 永远是 NULL,闸门恒不开 —— 计价一声不吭地算了出来。fu1 修正了顺序。
-- 一条守卫写在它所判断的那个值被读出来之前,和 FIN-13 那个空区间、OPS-17 那个
-- 同源自检是同一族:读起来很严,实际什么也没做,而且只能靠【让它失败一次】发现。
--
-- 【F 臂:异常判据按指数收窄】LME 与 SMM 本来就不同价,跨着比会天天报警 ——
-- 而天天报警的警报等于没有警报,人会学会点掉它,连真的那次一起点掉。
--
-- 【日期全部落在 2027,自带数据】(README 第 4/5 条)。行情序列由本 fixture 自己
-- 摆出来:既有数据里每个金属都已有报价,不清空就等于继承别人的参照。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid; v_mat uuid; v_pol uuid; v_po uuid; v_formula uuid; v_commit uuid;
    v_terms jsonb; v_calc jsonb; v_verdict jsonb;
    v_msg text; v_denied boolean;
    v_lme numeric; v_unstated numeric;
    v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;
    UPDATE pricing_settings SET metal_price_change_warn_pct = 50 WHERE id;
    -- 序列的起点是前提,不能继承(同 fixture 48)
    UPDATE metal_prices SET deleted_at = now() WHERE deleted_at IS NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-49', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.pricing.view','module.pricing.edit',
        'module.purchasing.view','module.inbound.view','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 三条序列,同一个金属同一天:LME 有价、SMM 有价、未标注也有价。
    -- 【三个数字彼此不同】—— 这是本 fixture 全部判别力的来源:取错序列就会算出
    -- 另一个数,而不是碰巧相同。
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source) VALUES
        ('cu', 10000, '2027-05-04', 'LME', 'broker_quote'),
        ('cu', 12000, '2027-05-04', 'SMM', 'broker_quote'),
        ('cu',  8000, '2027-05-04', NULL, 'broker_quote');

    -- ══════════ A. 三条序列同日共存(唯一键按指数分开)══════════════════════
    IF (SELECT count(*) FROM metal_prices
         WHERE metal='cu' AND price_date='2027-05-04' AND deleted_at IS NULL) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 49A 失败:同一金属同一天应能在三条序列上各存一条,实得 % 行 —— 唯一键若还是 (metal, price_date),第二条就插不进去,而 Doc 1 的 "LME or SMM" 就说不出来',
            (SELECT count(*) FROM metal_prices WHERE metal='cu' AND price_date='2027-05-04' AND deleted_at IS NULL);
    END IF;
    -- 但【同一条序列】上一天仍然只许一条(NULLS NOT DISTINCT 保住老规矩)
    v_denied := false;
    BEGIN
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source)
        VALUES ('cu', 9999, '2027-05-04', NULL, 'broker_quote');
    EXCEPTION WHEN unique_violation THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 49A 失败:同一天、同一金属、【同为未标注指数】的第二条价应被唯一键挡住 —— 少了 NULLS NOT DISTINCT,这条老规矩会恰好在既有 11 行所在的那条序列上失效';
    END IF;

    -- ══════════ B. 条款挑哪条序列,就用哪条的数字 ═══════════════════════════
    v_terms := jsonb_build_object('price_index','LME','price_basis','spot','average_days',NULL,
        'treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,
        'payables', jsonb_build_object('cu',100));
    v_calc := calculate_metal_price_from_terms(v_terms,
        jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-05-04');
    v_lme := (v_calc->>'unit_price_usd_per_kg')::numeric;

    v_terms := jsonb_set(v_terms, '{price_index}', 'null'::jsonb);
    v_calc := calculate_metal_price_from_terms(v_terms,
        jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-05-04');
    v_unstated := (v_calc->>'unit_price_usd_per_kg')::numeric;

    -- LME 10,000/吨 = 10 USD/kg;未标注 8,000/吨 = 8 USD/kg。
    IF v_lme <> 10 OR v_unstated <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 49B 失败:LME 条款应得 10 USD/kg、未声明指数的条款应得 8,实得 % 与 % —— 两者相等就说明取价没有按指数分开,那么"合同挑指数"这件事在系统里不存在',
            v_lme, v_unstated;
    END IF;

    -- ══════════ C. 声明了指数,就看不见【未标注】的行情(反之亦然)═══════════
    -- 把 LME 那条删掉:LME 条款此刻【无价可用】,而未标注序列上明明还有 8,000。
    UPDATE metal_prices SET deleted_at = now()
     WHERE metal='cu' AND price_date='2027-05-04' AND price_index='LME';
    v_terms := jsonb_build_object('price_index','LME','price_basis','spot','average_days',NULL,
        'treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,
        'payables', jsonb_build_object('cu',100));
    v_calc := calculate_metal_price_from_terms(v_terms,
        jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-05-04');
    IF NOT (v_calc->'skipped_metals' @> '"cu"'::jsonb) THEN
        RAISE EXCEPTION 'FIXTURE 49C 失败:LME 上没有行情时,cu 应当进 skipped_metals(报价路径据此点名拒绝),实得 % —— 若它悄悄用了未标注那条 8,000,系统就替那条报价宣称了它来自 LME',
            v_calc->'skipped_metals';
    END IF;
    IF (v_calc->>'unit_price_usd_per_kg')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 49C 失败:缺本指数行情时不应从别的序列取数,实得单价 %', v_calc->>'unit_price_usd_per_kg';
    END IF;
    -- 恢复 LME 那条,后面几臂要用
    UPDATE metal_prices SET deleted_at = NULL
     WHERE metal='cu' AND price_date='2027-05-04' AND price_index='LME';

    -- ══════════ D. 指数是条款:承诺之后不随公式改动(FIN-27 的形状)═════════
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX49-S', 'fixture 49 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZFIX49-M', 'fixture 49 material', 'battery_material', true) RETURNING id INTO v_mat;
    INSERT INTO pricing_formulas (code, name, direction, price_basis, price_index,
        treatment_charge_usd_per_tonne, flat_discount_pct)
    VALUES ('ZZFIX49-PF', 'fixture 49 formula', 'both', 'spot', 'LME', 0, 0)
    RETURNING id INTO v_formula;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct) VALUES (v_formula, 'cu', 100);

    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status)
    VALUES ('ZZFIX49-PO', v_sup, DATE '2027-05-01', v_ccy, 1, 'draft') RETURNING id INTO v_po;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, pricing_formula_id)
    VALUES (v_po, 1, v_mat, 1000, 'kg', v_formula) RETURNING id INTO v_pol;
    v_commit := commit_pricing_terms(v_formula, v_pol, NULL);

    -- 公式改判到 SMM —— 已成交的那一单不该跟着动
    UPDATE pricing_formulas SET price_index = 'SMM' WHERE id = v_formula;

    IF (pricing_terms_of_commitment(v_commit)->>'price_index') <> 'LME' THEN
        RAISE EXCEPTION 'FIXTURE 49D 失败:成交时抄下的指数应仍是 LME,实得 % —— 公式是模板,成交记录才是那笔交易;这一条与 FIN-27 对费率的规矩是同一条',
            pricing_terms_of_commitment(v_commit)->>'price_index';
    END IF;
    v_calc := calculate_metal_price_from_terms(pricing_terms_of_commitment(v_commit),
        jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-05-04');
    IF (v_calc->>'unit_price_usd_per_kg')::numeric <> 10 THEN
        -- 【判别力】抄下来的是 LME(10,000 USD/t → 10 USD/kg);公式已被改判到 SMM,
        -- 而 SMM 那条报价是另一个数、另一种币种 —— 跟着公式走就不可能还是 10。
        RAISE EXCEPTION 'FIXTURE 49D 失败:按抄下来的 LME 结算应得 10 USD/kg,实得 % —— 公式已被改判到 SMM(另一条序列、另一个数),算出别的数就说明它跟着模板走了,而不是跟着成交记录',
            v_calc->>'unit_price_usd_per_kg';
    END IF;

    -- ══════════ E. 报价币种未声明的指数【算不出钱】,而且是点名拒绝 ══════════
    -- 【本臂自己建一个没声明币种的指数,不依赖 SMM 恰好是空的】第一版直接拿 SMM
    -- 当例子 —— 那时它的 quote_currency 确实为空。METAL-3 里 Tim 回答了(CNY),
    -- 于是这一臂开始报"应当 INDEX_CURRENCY_NOT_STATED,实得 FX_RATE_MISSING"。
    -- 断言本身没错,错的是它把【一个会被人回答的业务决定】当成了固定前提
    -- (README 第 5 条:要什么前提就自己设,别继承)。它测的一直是【机制】:
    -- 没声明币种的指数不许算钱 —— 那就自己造一个没声明的。
    INSERT INTO metal_price_indices (code, name_en, name_zh, quote_currency, sort_order, notes)
    VALUES ('ZZFIX49-IDX', 'fixture 49 index', 'fixture 49 指数', NULL, 99,
            '本 fixture 自建:报价币种【故意不声明】,用来钉"没声明就不许算钱"这条闸门');
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source)
    VALUES ('cu', 11000, '2027-05-04', 'ZZFIX49-IDX', 'broker_quote');

    v_denied := false;
    BEGIN
        v_calc := calculate_metal_price_from_terms(
            jsonb_build_object('price_index','ZZFIX49-IDX','price_basis','spot','average_days',NULL,
                'treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,
                'payables', jsonb_build_object('cu',100)),
            jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-05-04');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'INDEX_CURRENCY_NOT_STATED|ZZFIX49-IDX' THEN
        RAISE EXCEPTION 'FIXTURE 49E 失败:报价币种未声明的指数,按它计价应点名拒绝,实得 denied=% msg=% —— 把它的数字默认当成美元,就是替这个市场宣称了一件没人说过的事(METAL-2 主迁移的第一版正是这样:闸门写在读出指数之前,恒不开)',
            v_denied, COALESCE(v_msg, '(算出来了)');
    END IF;

    -- 声明之后立刻可用 —— 这一臂同时证明那道闸门【拦的是缺席,不是某个指数的名字】
    UPDATE metal_price_indices
       SET quote_currency = 'USD', quote_currency_basis = 'contract'
     WHERE code = 'ZZFIX49-IDX';
    v_calc := calculate_metal_price_from_terms(
        jsonb_build_object('price_index','ZZFIX49-IDX','price_basis','spot','average_days',NULL,
            'treatment_charge_usd_per_tonne',0,'flat_discount_pct',0,
            'payables', jsonb_build_object('cu',100)),
        jsonb_build_array(jsonb_build_object('metal','cu','content_pct',100)), 1000, DATE '2027-05-04');
    IF (v_calc->>'unit_price_usd_per_kg')::numeric <> 11 THEN
        RAISE EXCEPTION 'FIXTURE 49E 失败:声明币种之后应得 11 USD/kg,实得 % —— 闸门该拦的是"没人声明",不是某个指数本身',
            v_calc->>'unit_price_usd_per_kg';
    END IF;

    -- ══════════ F. 异常判据按指数收窄 ═══════════════════════════════════════
    -- SMM 次日 13,000:与【SMM 自己的】12,000 相差 8.3%,不该报警;
    -- 若跨指数拿未标注那条 8,000 当参照,就是 +62.5%,会误报。
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source)
    VALUES ('cu', 13000, '2027-05-05', 'SMM', 'broker_quote');
    SELECT anomaly_check INTO v_verdict
      FROM metal_prices WHERE metal='cu' AND price_date='2027-05-05' AND price_index='SMM';
    IF v_verdict->>'verdict' <> 'inside' THEN
        RAISE EXCEPTION 'FIXTURE 49F 失败:SMM 12,000 → 13,000(+8.3%%)不该报警,实得 %(参照 % / 来自 %)—— 跨指数比较会天天报警,而天天报警的警报等于没有警报',
            v_verdict->>'verdict', v_verdict->>'reference_price', v_verdict->>'reference_date';
    END IF;
    IF (v_verdict->>'reference_price')::numeric <> 12000 THEN
        RAISE EXCEPTION 'FIXTURE 49F 失败:参照应当是【同一指数上】的上一条(12,000),实得 % —— 拿另一条序列的数字当参照,报出来的百分比是没有意义的',
            v_verdict->>'reference_price';
    END IF;
    -- 而【同一条序列内】的真跳变照样报:SMM 13,000 → 30,000 是 +130%
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source)
    VALUES ('cu', 30000, '2027-05-06', 'SMM', 'broker_quote');
    SELECT anomaly_check INTO v_verdict
      FROM metal_prices WHERE metal='cu' AND price_date='2027-05-06' AND price_index='SMM';
    IF v_verdict->>'verdict' <> 'outside' THEN
        RAISE EXCEPTION 'FIXTURE 49F 失败:同一指数内 13,000 → 30,000(+130%%)应当报警,实得 % —— 按指数收窄不该把判据一起关掉',
            v_verdict->>'verdict';
    END IF;
    -- 每个金属【在每个新指数上】的第一条仍然是 no_reference,不是"查过没问题"
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source)
    VALUES ('ni', 20000, '2027-05-06', 'SMM', 'broker_quote');
    SELECT anomaly_check INTO v_verdict
      FROM metal_prices WHERE metal='ni' AND price_date='2027-05-06' AND price_index='SMM';
    IF v_verdict->>'verdict' <> 'no_reference' THEN
        RAISE EXCEPTION 'FIXTURE 49F 失败:ni 在 SMM 上的第一条报价应判 no_reference,实得 % —— 两条序列之后这一种会更常见,而它依然不等于"查过、没问题"',
            v_verdict->>'verdict';
    END IF;
END $$;
ROLLBACK;
