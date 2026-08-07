-- 23 现金流量表:恒等式自洽、重估不是现金流、年结不出现、手工分录不塞进经营
--
-- 为什么值得常设(FIN-30):这张表最容易错的地方【不是加减法,是"什么算现金流"】。
-- 1010 每到期末被重估:它的【本位币账面值】变了,而一分钱没动。任何从本位币变动
-- 反推出来的现金流量表,都会把那笔重估印成一笔凭空的现金流 —— 数字看着完全正常,
-- 没有任何东西会不平,因为它确实平。四臂:
--   A 恒等式:期初 + 经营 + 投资 + 筹资 + 未归类 + 汇率影响 = 期末,
--     且期末 = 资产负债表口径下同一批科目的余额。区间里同时有收款、付款、
--     买固定资产、重估 —— 四种都在,恒等式仍成立。
--   B 【本切的要害】一个区间里 1010 只发生了重估:三段必须【全为 0】,
--     而汇率影响那一行【非零】。故障注入:把重估当普通现金流,本臂当场红。
--   C 区间里有年结分录:它不动现金,且【不该出现】—— 与损益表剔除它同一条规矩。
--     C 拆成两半,因为【只写前一半是空断言】:一笔不碰现金的年结分录,本来就
--     进不了"碰了现金的分录"这个集合 —— 剔不剔除 year_close 它都不出现,
--     于是那条过滤根本没被测到(实测:把过滤删掉,fixture 照样全绿)。
--     所以 C2 造一笔【碰了现金的】年结分录 —— 那是一笔坏账,现实里不该存在 ——
--     断言报表【说自己对不上】(ties=false),而不是把它悄悄吸收掉。
--     这也正是 Part D 那条自检的失败路径:对不上就说对不上。
--   D 手工分录碰了现金:它什么都不带,按构造无法归类 —— 单列"未归类",
--     【不塞进经营】。没有这一臂,"看不懂就算经营"也能过 A。
--
-- 【数字怎么来的】本 fixture 自带一套现金:期初注资 100,000(筹资),
-- 收款 6,000 / 付款 2,500(经营),买设备 8,000(投资),手工 300(未归类)。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_cash uuid; v_usd uuid; v_ar uuid; v_ap uuid; v_eq uuid; v_fa uuid; v_ex uuid; v_fxu uuid;
    v_from date := DATE '2026-03-01'; v_to date := DATE '2026-03-31';
    v_r jsonb; v_je jsonb; v_n integer; v_msg text; v_ok boolean;
    v_open numeric; v_close numeric; v_bs numeric;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-23', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    -- 前提显式设定(README 第 5 条):期间不锁,年结锁也不许挡路
    UPDATE finance_settings SET locked_before = NULL;
    DELETE FROM year_closes WHERE year_end >= DATE '2025-01-01';

    SELECT id INTO v_cash FROM accounts WHERE code = '1000';
    SELECT id INTO v_usd  FROM accounts WHERE code = '1010';
    SELECT id INTO v_ar   FROM accounts WHERE code = '1100';
    SELECT id INTO v_ap   FROM accounts WHERE code = '2000';
    SELECT id INTO v_eq   FROM accounts WHERE code = '3000';
    SELECT id INTO v_fa   FROM accounts WHERE code = '1500';
    SELECT id INTO v_ex   FROM accounts WHERE code = '6000';
    SELECT id INTO v_fxu  FROM accounts WHERE code = '7110';

    -- 【自证前提】这一切全靠两列声明工作;它们不对,后面每一个断言都失去意义。
    IF (SELECT count(*) FROM accounts WHERE is_cash) < 2
       OR NOT (SELECT is_cash FROM accounts WHERE code = '1010')
       OR (SELECT cash_flow_section FROM accounts WHERE code = '1500') IS DISTINCT FROM 'investing'
       OR (SELECT cash_flow_section FROM accounts WHERE code = '3000') IS DISTINCT FROM 'financing' THEN
        RAISE EXCEPTION 'FIXTURE 23 失败:前提不成立 —— is_cash / cash_flow_section 的声明不是预期的样子';
    END IF;

    -- ── 期初:2 月注资 100,000(区间之前,进期初余额,不进本期筹资)──────────
    PERFORM post_journal_entry(DATE '2026-02-10', 'Fixture 23 opening capital', 'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','1000','side','debit','currency','SGD','amount_ccy',100000),
            jsonb_build_object('account_code','3000','side','credit','currency','SGD','amount_ccy',100000)));

    -- ── 区间内 ────────────────────────────────────────────────────────────────
    -- 经营:收客户 6,000(对方 1100)
    PERFORM post_journal_entry(v_from + 2, 'Fixture 23 receipt', 'payment', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','1000','side','debit','currency','SGD','amount_ccy',6000),
            jsonb_build_object('account_code','1100','side','credit','currency','SGD','amount_ccy',6000)));
    -- 经营:付供应商 2,500(对方 2000)
    PERFORM post_journal_entry(v_from + 5, 'Fixture 23 supplier payment', 'payment', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','2000','side','debit','currency','SGD','amount_ccy',2500),
            jsonb_build_object('account_code','1000','side','credit','currency','SGD','amount_ccy',2500)));
    -- 投资:买设备 8,000(对方 1500 —— 声明为 investing)。
    -- 【注意 source_type 是 expense】同一个 source_type 既能是经营也能是投资,
    -- 判据取【对方科目】而不是 source_type,本行就是那个区别的活样本。
    PERFORM post_journal_entry(v_from + 9, 'Fixture 23 equipment', 'expense', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','1500','side','debit','currency','SGD','amount_ccy',8000),
            jsonb_build_object('account_code','1000','side','credit','currency','SGD','amount_ccy',8000)));
    -- 汇率影响:1010 重估 −1,200(账面值变,一分钱没动)
    PERFORM post_journal_entry(v_to, 'Fixture 23 revaluation', 'revaluation', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','7110','side','debit','currency','SGD','amount_ccy',1200),
            jsonb_build_object('account_code','1010','side','credit','currency','SGD','amount_ccy',1200)));

    -- ════════ A. 恒等式 ══════════════════════════════════════════════════════
    v_r := cash_flow_statement(v_from, v_to);
    v_open  := (v_r->>'opening_cash')::numeric;
    v_close := (v_r->>'closing_cash')::numeric;
    v_bs    := (v_r->>'closing_cash_balance_sheet')::numeric;

    IF v_open <> 100000 THEN
        RAISE EXCEPTION 'FIXTURE 23A 失败:期初现金应为 100000(2 月注资,区间之前),实得 %', v_open;
    END IF;
    IF (v_r->>'operating')::numeric <> 3500 THEN     -- 6000 − 2500
        RAISE EXCEPTION 'FIXTURE 23A 失败:经营应为 3500(收 6000 − 付 2500),实得 %', v_r->>'operating';
    END IF;
    IF (v_r->>'investing')::numeric <> -8000 THEN
        RAISE EXCEPTION 'FIXTURE 23A 失败:投资应为 −8000(买设备,判据是【对方科目 1500】而不是 source_type),实得 %',
            v_r->>'investing';
    END IF;
    IF (v_r->>'financing')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 23A 失败:本期无筹资活动(注资在区间之前),应为 0,实得 %', v_r->>'financing';
    END IF;
    IF (v_r->>'fx_effect')::numeric <> -1200 THEN
        RAISE EXCEPTION 'FIXTURE 23A 失败:汇率影响应为 −1200,实得 %', v_r->>'fx_effect';
    END IF;
    -- 恒等式本身
    IF v_close <> round(v_open + (v_r->>'operating')::numeric + (v_r->>'investing')::numeric
                        + (v_r->>'financing')::numeric + (v_r->>'unclassified')::numeric
                        + (v_r->>'fx_effect')::numeric, 2) THEN
        RAISE EXCEPTION 'FIXTURE 23A 失败:期末 % 不等于期初加各段之和', v_close;
    END IF;
    -- 【与资产负债表对得上】这一条才是"这张表没错"的证明,不是内部自洽
    IF v_close <> v_bs OR (v_r->>'ties')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 23A 失败:期末现金 % 与资产负债表口径 % 对不上(ties=%)',
            v_close, v_bs, v_r->>'ties';
    END IF;

    -- ════════ B. 只有重估的区间:三段全 0,汇率影响非零 ═══════════════════════
    -- 【本切的要害】重估改的是本位币账面值,没有现金动过。
    v_r := cash_flow_statement(v_to, v_to);   -- 只含重估那一天
    IF (v_r->>'operating')::numeric <> 0 OR (v_r->>'investing')::numeric <> 0
       OR (v_r->>'financing')::numeric <> 0 OR (v_r->>'unclassified')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 23B 失败:只发生了重估的区间,三段与未归类都必须为 0,实得 经营=% 投资=% 筹资=% 未归类=% —— 重估被当成了现金流',
            v_r->>'operating', v_r->>'investing', v_r->>'financing', v_r->>'unclassified';
    END IF;
    IF (v_r->>'fx_effect')::numeric <> -1200 THEN
        RAISE EXCEPTION 'FIXTURE 23B 失败:汇率影响应为 −1200(它确实改变了现金的本位币价值),实得 %',
            v_r->>'fx_effect';
    END IF;
    IF (v_r->>'ties')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 23B 失败:只有重估的区间也必须与资产负债表对得上';
    END IF;

    -- ════════ C. 区间里有年结分录:不动现金,且不出现 ═════════════════════════
    -- 年结把损益结进 3100。3100 声明为 financing —— 若不剔除 year_close,
    -- 这笔会被算成一大笔【筹资现金流】,而它一分钱没动。
    PERFORM post_journal_entry(v_from + 20, 'Fixture 23 year close', 'year_close', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','4000','side','debit','currency','SGD','amount_ccy',50000),
            jsonb_build_object('account_code','3100','side','credit','currency','SGD','amount_ccy',50000)));
    v_r := cash_flow_statement(v_from, v_to);
    IF (v_r->>'financing')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 23C 失败:年结分录不动现金,筹资应仍为 0,实得 % —— year_close 没有被剔除',
            v_r->>'financing';
    END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_r->'entries') x
    WHERE x->>'source_type' = 'year_close';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 23C 失败:年结分录不该出现在现金流量表的明细里,实得 % 条', v_n;
    END IF;
    IF (v_r->>'ties')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 23C 失败:含年结的区间仍必须与资产负债表对得上';
    END IF;

    -- ════════ D. 手工分录碰现金:单列未归类,不塞进经营 ═══════════════════════
    PERFORM post_journal_entry(v_from + 25, 'Fixture 23 manual cash', 'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','1000','side','debit','currency','SGD','amount_ccy',300),
            jsonb_build_object('account_code','4900','side','credit','currency','SGD','amount_ccy',300)));
    v_r := cash_flow_statement(v_from, v_to);
    IF (v_r->>'unclassified')::numeric <> 300 THEN
        RAISE EXCEPTION 'FIXTURE 23D 失败:手工分录按构造无法归类,应单列 300 到未归类,实得 %',
            v_r->>'unclassified';
    END IF;
    IF (v_r->>'operating')::numeric <> 3500 THEN
        RAISE EXCEPTION 'FIXTURE 23D 失败:手工那 300 不该混进经营(经营应仍是 3500),实得 % —— "看不懂就算经营"是个默认桶,不是答案',
            v_r->>'operating';
    END IF;
    -- 未归类照样进恒等式:它是报表的一部分,不是被丢掉的余数
    IF (v_r->>'ties')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 23D 失败:有未归类项时恒等式仍必须成立(未归类要计进期末),实得 ties=%',
            v_r->>'ties';
    END IF;

    -- ════════ C2. 【坏账】年结分录碰了现金:报表必须说自己对不上 ═══════════════
    -- 现实里年结不碰现金,所以 C1 那半是【空断言】—— 不碰现金的分录本来就进不了
    -- "碰了现金的分录"这个集合,剔除与否都一样(实测过:删掉过滤,fixture 照样绿)。
    -- 这一半让那条过滤真正吃上力:一笔碰了现金的年结分录被【movements 剔除】,
    -- 却仍在【资产负债表口径的期末余额】里(资产负债表包含 year_close)——
    -- 两个数于是对不上,而报表的职责是【说出来】,不是印一个不平的数。
    PERFORM post_journal_entry(v_from + 26, 'Fixture 23 malformed year close', 'year_close', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','1000','side','debit','currency','SGD','amount_ccy',700),
            jsonb_build_object('account_code','3100','side','credit','currency','SGD','amount_ccy',700)));
    v_r := cash_flow_statement(v_from, v_to);
    IF (v_r->>'ties')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 23C2 失败:碰了现金的年结分录应让报表报 ties=false(期末 % vs 资产负债表 %),实得 ties=% —— 它被悄悄吸收进了某一段',
            v_r->>'closing_cash', v_r->>'closing_cash_balance_sheet', v_r->>'ties';
    END IF;
    IF (v_r->>'closing_cash_balance_sheet')::numeric - (v_r->>'closing_cash')::numeric <> 700 THEN
        RAISE EXCEPTION 'FIXTURE 23C2 失败:两个期末数应恰好差那 700,实得差 %',
            (v_r->>'closing_cash_balance_sheet')::numeric - (v_r->>'closing_cash')::numeric;
    END IF;
END $$;
ROLLBACK;
