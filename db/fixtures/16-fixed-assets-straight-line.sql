-- 16 固定资产:从在役日起算、算术幂等、封顶、非货币不重估、处置清零、锁期点名拒
--
-- 为什么值得常设(FIN-22):折旧每月跑一次,错了不报错 —— 多提、重提、提过头、
-- 或者资产被重估,账面照样平,只是资产负债表悄悄不对。六臂各钉一条:
--   A 在役日中途投用 → 从【在役日】按天折,不从购置日;
--   B 同期第二次跑 → 应提 0,不过账(幂等靠算术,不靠闸);
--   C 折到 成本−残值 封顶,永不越过;
--   D USD 资产按【购置日】汇率定格,revalue_foreign_balances 零 movement;
--   E 处置把该资产的 1500/1510 恰好清零,差额进 7200;
--   F 期末落在锁定期间 → PERIOD_LOCKED 点名拒绝(应提为 0 也不许)。
--
-- 【字面量即断言对象的,推导写在旁边】(README 第 1 条)。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    v_sup uuid; v_r jsonb; v_asset uuid; v_asset_usd uuid;
    v_dep numeric; v_total numeric; v_je_count int; v_je_count2 int;
    v_msg text; v_ok boolean;
    v_lines record;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-16', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    -- 期间锁是运行时状态:先清掉,F 臂自己再设(README 第 5 条)
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('FIXT-S16', 'Fixture Supplier 16', 'SG', 'goods_supplier')
        RETURNING id INTO v_sup;

    -- ════════════════════════════════════════════════════════════════════════
    -- A. 购置 3/1,在役 3/16(三月 31 天)。成本 1000 SGD,残值 0,寿命 10 个月
    --    → 月折旧 100。期末 3/31 应提 = 100 × 16/31 = 51.6129… → 51.61。
    --    【如果从购置日起算会得 100】—— 两种实现差一倍,断言分得开。
    -- ════════════════════════════════════════════════════════════════════════
    v_r := record_expense('2026-03-01', '1500', 1000, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('description', 'Fixture press A', 'useful_life_months', 10,
                           'in_service_date', '2026-03-16'));
    v_asset := (v_r->>'asset_id')::uuid;
    IF v_asset IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 16A 前提失败:资本支出未生成台账行';
    END IF;

    v_r := depreciate_fixed_assets('2026-03-31');
    SELECT COALESCE(SUM(amount_base), 0) INTO v_dep FROM fixed_asset_depreciation WHERE asset_id = v_asset;
    IF v_dep <> 51.61 THEN
        RAISE EXCEPTION 'FIXTURE 16A 失败:3/16 在役、期末 3/31 应提 51.61(= 100 × 16/31,从在役日按天;从购置日起算会是 100),实得 %', v_dep;
    END IF;

    -- ── B. 同期第二次跑:应提 0,不过账、不加行 ─────────────────────────────
    SELECT count(*) INTO v_je_count FROM journal_entries WHERE source_type = 'depreciation';
    v_r := depreciate_fixed_assets('2026-03-31');
    IF (v_r->>'total_posted')::numeric <> 0 OR (v_r->>'journal_code') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 16B 失败:同期第二次跑应提 0 且不过账,实得 total_posted=% journal=%',
            v_r->>'total_posted', v_r->>'journal_code';
    END IF;
    SELECT count(*) INTO v_je_count2 FROM journal_entries WHERE source_type = 'depreciation';
    IF v_je_count2 <> v_je_count THEN
        RAISE EXCEPTION 'FIXTURE 16B 失败:第二次跑多出了分录(% → %)', v_je_count, v_je_count2;
    END IF;

    -- ── C. 跑到寿命尽头之后:封顶在 成本−残值,永不越过 ─────────────────────
    --    A 的资产残值 0 → 封顶 1000。2027-06-30 已远超 10 个月寿命。
    v_r := depreciate_fixed_assets('2027-06-30');
    SELECT COALESCE(SUM(amount_base), 0) INTO v_dep FROM fixed_asset_depreciation WHERE asset_id = v_asset;
    IF v_dep <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 16C 失败:寿命尽头累计折旧应恰为 成本−残值 = 1000,实得 %', v_dep;
    END IF;
    v_r := depreciate_fixed_assets('2027-12-31');
    SELECT COALESCE(SUM(amount_base), 0) INTO v_dep FROM fixed_asset_depreciation WHERE asset_id = v_asset;
    IF v_dep <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 16C 失败:封顶后继续跑不得越过 1000,实得 %', v_dep;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- D. USD 资产:按【购置日】汇率定格;期末汇率变了,重估对 1500/1510 零 movement
    --    购置日 6/15(周一)牌价 1.25(自插);USD 2,000 → cost_base 2,500。
    --    期末 6/30(周二)中间价 1.40(自插)—— 若有人把 1500 加进重估,
    --    这里会顶出 2000 × (1.40 − 1.25) = 300 的调整。断言:预览行里没有 1500/1510。
    -- ════════════════════════════════════════════════════════════════════════
    UPDATE fx_rates SET deleted_at = now() WHERE currency = 'USD' AND rate_date BETWEEN '2026-06-13' AND '2026-06-30';
    DELETE FROM public_holidays WHERE holiday_date BETWEEN '2026-06-13' AND '2026-06-30';
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', '2026-06-15', 'tt_sell', 1.25), ('USD', '2026-06-30', 'mid', 1.40),
           ('USD', '2026-06-30', 'tt_buy', 1.40), ('USD', '2026-06-30', 'tt_sell', 1.40);
    v_r := record_expense('2026-06-15', '1500', 2000, 'USD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('description', 'Fixture imported mill', 'useful_life_months', 60,
                           'in_service_date', '2026-07-01'));
    v_asset_usd := (v_r->>'asset_id')::uuid;
    SELECT fx_rate, cost_base INTO v_dep, v_total FROM fixed_assets WHERE id = v_asset_usd;
    IF v_dep <> 1.25 OR v_total <> 2500 THEN
        RAISE EXCEPTION 'FIXTURE 16D 失败:USD 资产应按购置日 1.25 定格为 2500,实得 fx=% cost_base=%', v_dep, v_total;
    END IF;
    -- 重估预览必须【看不见】1500/1510(非货币);它们的 movement 恒为零
    v_r := preview_revalue_foreign_balances('2026-06-30');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'rows') r
               WHERE r->>'account' IN ('1500','1510')) THEN
        RAISE EXCEPTION 'FIXTURE 16D 失败:重估扫到了 1500/1510 —— 固定资产是非货币项目,谁把它加进重估了?';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- E. 处置:1500/1510 对该资产恰好清零,差额进 7200
    --    A 的资产:成本 1000,累计已封顶 1000。卖 150(SGD 户):
    --    借 1000(银行 150 + 1510 1000)…贷 1500 1000,差额 150 贷 7200(益)。
    -- ════════════════════════════════════════════════════════════════════════
    v_r := dispose_fixed_asset(v_asset, '2027-12-31', 150, '1000', 'fixture sale');
    IF (v_r->>'cost_relieved')::numeric <> 1000 OR (v_r->>'accum_relieved')::numeric <> 1000
       OR (v_r->>'gain_loss')::numeric <> 150 THEN
        RAISE EXCEPTION 'FIXTURE 16E 失败:处置应解除成本 1000/累计 1000、损益 +150,实得 %', v_r::text;
    END IF;
    -- 该资产在 1500 的净额:资本支出借 1000 − 处置贷 1000 = 0;1510 同理。
    -- 重建库无其他业务数据,但 D 臂的 USD 资产也挂在 1500 上 —— 按分录逐笔核对:
    SELECT
        COALESCE(SUM(CASE WHEN a.code = '1500' THEN l.credit END), 0),
        COALESCE(SUM(CASE WHEN a.code = '1510' THEN l.debit  END), 0)
    INTO v_dep, v_total
    FROM journal_lines l JOIN accounts a ON a.id = l.account_id
    JOIN journal_entries e ON e.id = l.entry_id
    WHERE e.source_type = 'asset_disposal' AND e.source_id = v_asset;
    IF v_dep <> 1000 OR v_total <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 16E 失败:处置分录应贷 1500=1000、借 1510=1000,实得 % / %', v_dep, v_total;
    END IF;
    IF (SELECT status FROM fixed_assets WHERE id = v_asset) <> 'disposed' THEN
        RAISE EXCEPTION 'FIXTURE 16E 失败:资产未标记 disposed';
    END IF;
    -- 已处置资产不再计提:再跑一次,累计不动
    v_r := depreciate_fixed_assets('2028-06-30');
    SELECT COALESCE(SUM(amount_base), 0) INTO v_dep FROM fixed_asset_depreciation WHERE asset_id = v_asset;
    IF v_dep <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 16E 失败:已处置资产继续被计提,累计 %', v_dep;
    END IF;

    -- ── F. 锁定期间:点名拒绝(哪怕应提为 0)───────────────────────────────
    UPDATE finance_settings SET locked_before = '2026-04-01';
    v_ok := false;
    BEGIN
        PERFORM depreciate_fixed_assets('2026-03-31');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'PERIOD_LOCKED|2026-03-31|%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 16F 失败:锁内期末应抛 PERIOD_LOCKED|2026-03-31|…,实得:%', COALESCE(v_msg, '(没有报错)');
    END IF;
END $$;
ROLLBACK;
