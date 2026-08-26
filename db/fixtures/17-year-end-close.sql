-- 17 年结:按类型结转(FX 臂抓编号区间)、资产负债科目原样、幂等、
--    损益表复原、YEAR_CLOSED 点名拒(穿月锁路径)、重开恢复到分毫不差
--
-- 为什么值得常设(FIN-23):年结错了,留存收益悄悄错着,账面照样平。六臂:
--   A 收入+成本+费用+【FX 收益 7100】全部清零,3100 = 净结果 ——
--     7100 是 account_type='expense' 但编号在 7xxx:写成 4000-6999 区间的实现
--     会漏掉它,留存收益恰好错一个汇兑结果。这一臂就是抓那个的。
--   B 资产负债科目关年前后一字不差(整组快照比对;3100 例外,它就是接收方)。
--   C 第二次跑什么都不过账(幂等靠算术)。
--   D 关年之后,当年损益表(剔除 year_close 的口径)与关年之前逐科目相等。
--   E 回填分录:reopen_period 把月锁退回已结年内 → YEAR_CLOSED 点名拒 ——
--     这正是月级重开穿不透年闸的那条路径,年闸存在的全部理由。
--   F 重开年:试算表(逐科目借/贷合计)回到关年前的快照,分毫不差。
--
-- 【前提显式设定】财年配置、system_start、期间锁全部自己设(README 第 5 条);
-- 数据自带(重建库为空;对线上跑时先把重估/折旧跑平,断言全部按计算值,不按
-- 只在空库里成立的字面量)。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_r jsonb; v_msg text; v_ok boolean;
    v_pnl_before jsonb; v_pnl_after jsonb;
    v_bs_before jsonb; v_bs_after jsonb;
    v_tb_before jsonb; v_tb_after jsonb;
    v_net_expected numeric; v_7100_net numeric; v_3100_delta numeric;
    v_bad int; v_je_count int; v_je_count2 int;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-17', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    -- 【SOD-1:2026 年的账是【布景】,不是某个人做的一次自由裁量的调整】
    -- 年结会把锁推到 2027-01-01,而 SOD_POST_AND_CLOSE 拦的正是"在这个期间里
    -- 记过手工凭证的人来关它"。下面这三笔是这一年的账本身,不是谁的调整 ——
    -- 所以它们【没有主语】:claims 留空时 auth.uid() 为 NULL,created_by 落 NULL,
    -- 规矩没有可比的对象。claims 在布景搭完之后才设上,给真正被测的那些动作用。
    -- 本 fixture 测的是年结,不是职责分离;后者由 db/fixtures/127 自己测。

    -- 前提全部显式:财年 12/31、首年不 override、完整记录自 2026-01-01、锁清空
    UPDATE finance_settings SET locked_before = NULL, fy_end_month = 12, fy_end_day = 31,
        first_fy_end = NULL, system_start_date = '2026-01-01';

    -- ── 2026 年的账:收入 + FX 收益;材料成本;房租。全 SGD(重估无外币敞口)──
    -- 收款 13,000:销售 10,000 + 已实现汇兑收益 3,000(7100 贷方 —— FX 臂的主角)
    PERFORM post_journal_entry('2026-05-15', 'fixture sale + fx gain', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1000','side','debit','currency','SGD','amount_ccy',13000,'fx_rate',1),
        jsonb_build_object('account_code','4000','side','credit','currency','SGD','amount_ccy',10000,'fx_rate',1),
        jsonb_build_object('account_code','7100','side','credit','currency','SGD','amount_ccy',3000,'fx_rate',1)));
    PERFORM post_journal_entry('2026-06-20', 'fixture material cost', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','5000','side','debit','currency','SGD','amount_ccy',4000,'fx_rate',1),
        jsonb_build_object('account_code','1000','side','credit','currency','SGD','amount_ccy',4000,'fx_rate',1)));
    PERFORM post_journal_entry('2026-07-10', 'fixture rent', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','6000','side','debit','currency','SGD','amount_ccy',1000,'fx_rate',1),
        jsonb_build_object('account_code','1000','side','credit','currency','SGD','amount_ccy',1000,'fx_rate',1)));

    -- 布景搭完 —— 从这里起,动作有主语了。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    -- 硬前置自证:把重估与折旧【跑平】(对线上跑本 fixture 时它们可能欠着;
    -- 空库上是 no-op)。缺 12/31 中间价会让重估预览拒 —— 自插。
    UPDATE fx_rates SET deleted_at = now() WHERE rate_date = '2026-12-31';
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD','2026-12-31','mid',1.30),('USD','2026-12-31','tt_buy',1.30),('USD','2026-12-31','tt_sell',1.30);
    PERFORM depreciate_fixed_assets('2026-12-31');
    PERFORM revalue_foreign_balances('2026-12-31');

    -- 月结:锁推过年末(年结【断言】锁位,不动它)
    PERFORM close_period('2026-12-31');

    -- ── 快照:关年之前 ──────────────────────────────────────────────────────
    -- 当年损益表口径(剔除 year_close —— 与 app/finance/pnl 的口径一致)
    SELECT COALESCE(jsonb_object_agg(t.code, t.net), '{}'::jsonb) INTO v_pnl_before FROM (
        SELECT a.code, round(SUM(jl.credit) - SUM(jl.debit), 2) AS net
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        JOIN journal_entries je ON je.id = jl.entry_id
        WHERE a.account_type IN ('revenue','cogs','expense')
          AND je.entry_date BETWEEN '2026-01-01' AND '2026-12-31'
          AND je.source_type IS DISTINCT FROM 'year_close'
        GROUP BY a.code HAVING round(SUM(jl.credit) - SUM(jl.debit), 2) <> 0) t;
    -- 资产负债科目整组快照(3100 除外 —— 它是结转的接收方)
    SELECT COALESCE(jsonb_object_agg(t.code, t.net), '{}'::jsonb) INTO v_bs_before FROM (
        SELECT a.code, round(SUM(jl.debit) - SUM(jl.credit), 2) AS net
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        WHERE a.account_type IN ('asset','liability','equity') AND a.code <> '3100'
        GROUP BY a.code HAVING round(SUM(jl.debit) - SUM(jl.credit), 2) <> 0) t;
    -- 预期净结果 + 7100 的净额(结转前);试算表整表快照(F 臂用)
    SELECT round(COALESCE(SUM(jl.credit) - SUM(jl.debit), 0), 2) INTO v_net_expected
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    JOIN journal_entries je ON je.id = jl.entry_id
    WHERE a.account_type IN ('revenue','cogs','expense') AND je.entry_date <= '2026-12-31';
    SELECT round(COALESCE(SUM(jl.credit) - SUM(jl.debit), 0), 2) INTO v_7100_net
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
    WHERE a.code = '7100';
    SELECT COALESCE(jsonb_object_agg(t.code, jsonb_build_array(t.d, t.c)), '{}'::jsonb) INTO v_tb_before FROM (
        SELECT a.code, round(SUM(jl.debit),2) AS d, round(SUM(jl.credit),2) AS c
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        GROUP BY a.code) t;
    SELECT round(COALESCE(SUM(jl.debit) - SUM(jl.credit), 0), 2) INTO v_3100_delta
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE a.code = '3100';

    -- ════════════════ A. 关年:每个损益科目恰好清零,3100 = 净结果 ═══════════
    v_r := close_financial_year('2026-12-31', 'fixture close');
    IF (v_r->>'net_result')::numeric <> v_net_expected THEN
        RAISE EXCEPTION 'FIXTURE 17A 失败:net_result 应为计算值 %,实得 %', v_net_expected, v_r->>'net_result';
    END IF;
    -- 空库上净结果 = 10000 + 3000 − 4000 − 1000 = 8000(字面量推导;线上跑为计算值)
    SELECT count(*) INTO v_bad FROM (
        SELECT a.code FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        JOIN journal_entries je ON je.id = jl.entry_id
        WHERE a.account_type IN ('revenue','cogs','expense') AND je.entry_date <= '2026-12-31'
        GROUP BY a.code HAVING round(SUM(jl.credit) - SUM(jl.debit), 2) <> 0) q;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'FIXTURE 17A 失败:关年后仍有 % 个损益科目未清零(编号区间漏科目的味道)', v_bad;
    END IF;
    -- FX 臂:结转分录里必须有 7100 的行,金额 = 它结转前的净额 ——
    -- 4000-6999 的区间实现在这里当场翻脸
    IF v_7100_net <> 0 THEN
        SELECT count(*) INTO v_bad
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        JOIN journal_entries je ON je.id = jl.entry_id
        WHERE je.source_type = 'year_close' AND a.code = '7100'
          AND round(CASE WHEN v_7100_net > 0 THEN jl.debit ELSE jl.credit END, 2) = abs(v_7100_net);
        IF v_bad = 0 THEN
            RAISE EXCEPTION 'FIXTURE 17A 失败:结转分录没有把 7100(净额 %)清零 —— 谁在用编号区间挑损益科目?', v_7100_net;
        END IF;
    END IF;
    -- 3100 接住净结果
    SELECT round(COALESCE(SUM(jl.debit) - SUM(jl.credit), 0), 2) - v_3100_delta INTO v_3100_delta
    FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE a.code = '3100';
    IF v_3100_delta <> -v_net_expected THEN
        RAISE EXCEPTION 'FIXTURE 17A 失败:3100 应增贷 %(盈利),实际借净变动 %', v_net_expected, v_3100_delta;
    END IF;

    -- ════════════════ B. 资产负债科目一字不差(整组快照)════════════════════
    SELECT COALESCE(jsonb_object_agg(t.code, t.net), '{}'::jsonb) INTO v_bs_after FROM (
        SELECT a.code, round(SUM(jl.debit) - SUM(jl.credit), 2) AS net
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        WHERE a.account_type IN ('asset','liability','equity') AND a.code <> '3100'
        GROUP BY a.code HAVING round(SUM(jl.debit) - SUM(jl.credit), 2) <> 0) t;
    IF v_bs_after <> v_bs_before THEN
        RAISE EXCEPTION 'FIXTURE 17B 失败:资产负债科目在关年中被动了。前 % 后 %', v_bs_before, v_bs_after;
    END IF;

    -- ════════════════ C. 第二次跑:什么都不过账 ═════════════════════════════
    SELECT count(*) INTO v_je_count FROM journal_entries WHERE source_type = 'year_close';
    v_r := close_financial_year('2026-12-31', 'fixture second run');
    IF NOT (v_r->>'already_closed')::boolean OR (v_r->>'journal_code') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 17C 失败:第二次跑应 already_closed 且不过账,实得 %', v_r::text;
    END IF;
    SELECT count(*) INTO v_je_count2 FROM journal_entries WHERE source_type = 'year_close';
    IF v_je_count2 <> v_je_count THEN
        RAISE EXCEPTION 'FIXTURE 17C 失败:第二次跑多出了分录(% → %)', v_je_count, v_je_count2;
    END IF;

    -- ════════════════ D. 当年损益表复原如初(剔除 year_close 的口径)═════════
    SELECT COALESCE(jsonb_object_agg(t.code, t.net), '{}'::jsonb) INTO v_pnl_after FROM (
        SELECT a.code, round(SUM(jl.credit) - SUM(jl.debit), 2) AS net
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        JOIN journal_entries je ON je.id = jl.entry_id
        WHERE a.account_type IN ('revenue','cogs','expense')
          AND je.entry_date BETWEEN '2026-01-01' AND '2026-12-31'
          AND je.source_type IS DISTINCT FROM 'year_close'
        GROUP BY a.code HAVING round(SUM(jl.credit) - SUM(jl.debit), 2) <> 0) t;
    IF v_pnl_after <> v_pnl_before THEN
        RAISE EXCEPTION 'FIXTURE 17D 失败:关年改动了当年损益表。前 % 后 %', v_pnl_before, v_pnl_after;
    END IF;

    -- ════════════════ E. 穿月锁路径:YEAR_CLOSED 点名拒 ═════════════════════
    -- reopen_period 把 locked_before 从 2027-01-01 退回(本 fixture 只关过 12 月
    -- → 退到解除)—— 月锁不再挡道,年闸必须自己站住。这正是它存在的理由。
    PERFORM reopen_period('2026-12-31', 'fixture: pierce the month lock');
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM post_journal_entry('2026-09-15', 'fixture backdated', 'manual', NULL, jsonb_build_array(
            jsonb_build_object('account_code','6000','side','debit','currency','SGD','amount_ccy',10,'fx_rate',1),
            jsonb_build_object('account_code','1000','side','credit','currency','SGD','amount_ccy',10,'fx_rate',1)));
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'YEAR_CLOSED|2026-09-15|2026-12-31%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 17E 失败:月锁退开后,回填 2026 应被 YEAR_CLOSED|2026-09-15|2026-12-31 点名拒,实得:%',
            COALESCE(v_msg, '(没有报错 —— 月级重开穿透了已结年度!)');
    END IF;

    -- ════════════════ F. 重开年:试算表回到关年前,分毫不差 ═════════════════
    v_r := reopen_financial_year('2026-12-31', 'fixture: adjust after audit');
    IF (v_r->>'reversal_journal_code') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 17F 失败:重开没有留下冲销分录';
    END IF;
    SELECT COALESCE(jsonb_object_agg(t.code, jsonb_build_array(t.d, t.c)), '{}'::jsonb) INTO v_tb_after FROM (
        SELECT a.code, round(SUM(jl.debit),2) AS d, round(SUM(jl.credit),2) AS c
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        JOIN journal_entries je ON je.id = jl.entry_id
        WHERE je.source_type IS DISTINCT FROM 'year_close'
        GROUP BY a.code) t;
    -- 试算表比较剔除 year_close 对(结转+冲销互为镜像,净效应为零;
    -- 【净额】必须回到原点 —— 用含 year_close 的净额整表断言:
    -- 【零净额不入快照】重开后 3100 的借贷恰好互抵(结转 + 冲销),净额 0 ——
    -- 一边有 "3100": 0.00 一边没这个键,是快照形状差异,不是账差。两边都滤掉零。
    SELECT COALESCE(jsonb_object_agg(t.code, t.net), '{}'::jsonb) INTO v_tb_after FROM (
        SELECT a.code, round(SUM(jl.debit) - SUM(jl.credit), 2) AS net
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        GROUP BY a.code HAVING round(SUM(jl.debit) - SUM(jl.credit), 2) <> 0) t;
    SELECT COALESCE(jsonb_object_agg(t.code, t.net), '{}'::jsonb) INTO v_tb_before FROM (
        SELECT t2.code, round((t2.v->>0)::numeric - (t2.v->>1)::numeric, 2) AS net
        FROM (SELECT key AS code, value AS v FROM jsonb_each(v_tb_before)) t2
        WHERE round((t2.v->>0)::numeric - (t2.v->>1)::numeric, 2) <> 0) t;
    IF v_tb_after <> v_tb_before THEN
        RAISE EXCEPTION 'FIXTURE 17F 失败:重开后试算表净额未回到关年前。前 % 后 %', v_tb_before, v_tb_after;
    END IF;
    -- 重开留痕:行还在、盖了章、记了冲销分录
    IF NOT EXISTS (SELECT 1 FROM year_closes WHERE year_end = '2026-12-31'
                   AND reopened_at IS NOT NULL AND reopen_reason IS NOT NULL
                   AND reversal_journal_id IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 17F 失败:year_closes 行未正确盖章留痕';
    END IF;
END $$;
ROLLBACK;
