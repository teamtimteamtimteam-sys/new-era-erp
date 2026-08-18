-- 77 固定资产:投用之前一直在攒成本,投用那一刻冻住并开始折旧;
--    而折旧还欠着的月份【锁不进去】(FA-1a)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的东西】
--
--   ① 【一台机器,几笔钱】运费/关税/安装调试与机器本体属于同一台资产。
--      追加走【同一扇门】(record_expense 的资本分支,p_asset 带 asset_id),
--      而不是第二个函数 —— 1500 ↔ p_asset 那个互相要求只守得住一扇门。
--   ② 【每一笔带自己的汇率】进口机器按购置日折算、本地运费按运费日折算。
--      合计只有 cost_base 一个数,而各笔的原币可以不同 —— 所以明细表存在,
--      "这个数怎么来的"才答得出来。B 臂用两个不同币种、不同汇率的追加钉住它。
--   ③ 【投用即冻结】投用之后再追加成本 → 按名拒。理由不是洁癖:投用那一刻起
--      折旧按当时的成本算,事后加钱会让已经提过的那几期全错,而它们可能已经
--      锁进期间。C 臂。
--   ④ 【折旧还欠着就锁不进去】月结链条的注释一直写着"锁进去的月份都要包含它",
--      而 FA-0 实测 lock 只看重估。E 臂三态:欠着 → 点名拒并说出金额;
--      提完了(差额 0)→ 放行;根本没有资产 → 放行。
--
-- 【注入放在最后】两道单层守卫各注一次:投用检查与锁那道闸,表上都没有兜底。
-- 原样定义在任何注入之前一次取齐(fixture 74/75 的教训)。
-- 自带数据(README 第 2 条);期间锁显式清空(第 5 条);日期全部落在 2028,
-- 与引导数据和随月末移动的状态无关(第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid;
    v_r jsonb; v_asset uuid; v_asset2 uuid;
    v_msg text; v_denied boolean; v_n integer; v_cost numeric; v_dep numeric;
    def_rec text; def_close text; def_sis text;
    v_inj text;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-77', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;

    -- 【原样定义在任何注入之前取齐】临用临取会取到已经被上一个注入改过的那一份
    def_rec   := pg_get_functiondef(-- PAYEE-1a:签名多了 p_employee_id(往来对象二选一),这里跟着改。
    --【它把签名钉死是对的】—— 注入要替换的就是这一个具体的函数。
    'public.record_expense(date,text,numeric,text,numeric,text,text,uuid,text,text,jsonb,uuid)'::regprocedure);
    def_close := pg_get_functiondef('public.close_period(date,text)'::regprocedure);
    def_sis   := pg_get_functiondef('public.set_asset_in_service(uuid,date)'::regprocedure);

    INSERT INTO suppliers (code, legal_name, country)
    VALUES ('FIXT-S77', 'Fixture Supplier 77', 'SG') RETURNING id INTO v_sup;
    -- 汇率:USD 那两天各一个(资产按【自己那天】的牌价定格)
    -- 【汇率由库给,不由调用方给】record_expense 对非结算路径拒绝外来汇率
    -- (FX_RATE_NOT_ACCEPTED)—— 那正是 FX 规矩:一处实现,页面不自己算。
    -- 两笔 USD 支出各在自己那天取牌价,所以两天都要有行。
    INSERT INTO fx_rates (rate_date, currency, rate_type, rate_sgd_per_unit)
    VALUES ('2028-03-02', 'USD', 'tt_sell', 1.30), ('2028-03-02', 'USD', 'mid', 1.30),
           ('2028-03-12', 'USD', 'tt_sell', 1.30), ('2028-03-12', 'USD', 'mid', 1.30)
    ON CONFLICT DO NOTHING;

    -- ══════════ A. 买机器:一笔,一台,明细里有一行 ═══════════════════════════
    v_r := record_expense('2028-03-02', '1500', 10000, 'USD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('description', 'Fixture line 77', 'useful_life_months', 100));
    v_asset := (v_r->>'asset_id')::uuid;
    IF v_asset IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 77A 前提失败:资本支出未生成台账行';
    END IF;
    IF (SELECT in_service_date FROM fixed_assets WHERE id = v_asset) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 77A 失败:没给投用日就该留空 —— 机器先到、后调试、再投产,中间那段它不该折旧';
    END IF;
    -- 【第一笔也进明细】否则第一笔查 expenses、后续几笔查明细表,两处读法
    IF (SELECT count(*) FROM fixed_asset_cost_entries WHERE asset_id = v_asset) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 77A 失败:购置那一笔也该在成本明细里';
    END IF;
    -- 10000 USD × 1.30 = 13000
    SELECT cost_base INTO v_cost FROM fixed_assets WHERE id = v_asset;
    IF v_cost <> 13000 THEN
        RAISE EXCEPTION 'FIXTURE 77A 失败:成本应为 10000 USD × 1.30 = 13000,实得 %', v_cost;
    END IF;
    -- 【还没投用 → 一分不提】FA-0 验过的那个 NULL 行为,这里正面钉住
    v_r := depreciate_fixed_assets('2028-03-31');
    IF (v_r->>'total_posted')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 77A 失败:未投用的资产不该提折旧,实得 %', v_r->>'total_posted';
    END IF;

    -- ══════════ B. 追加两笔:不同币种、不同汇率,合计对得上 ═══════════════════
    -- 本地运费 650 SGD(汇率 1)
    v_r := record_expense('2028-03-10', '1500', 650, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset));
    IF (v_r->>'asset_mode') <> 'append' THEN
        RAISE EXCEPTION 'FIXTURE 77B 失败:带 asset_id 应当走追加模式,实得 %', v_r::text;
    END IF;
    IF (v_r->>'asset_id')::uuid <> v_asset THEN
        RAISE EXCEPTION 'FIXTURE 77B 失败:追加不该造出第二台资产';
    END IF;
    -- 安装调试 1000 USD @ 1.30 = 1300
    PERFORM record_expense('2028-03-12', '1500', 1000, 'USD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset));

    IF (SELECT count(*) FROM fixed_assets) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 77B 失败:三笔支出应当只有一台资产,实得 % 台', (SELECT count(*) FROM fixed_assets);
    END IF;
    -- 13000 + 650 + 1300 = 14950
    SELECT cost_base INTO v_cost FROM fixed_assets WHERE id = v_asset;
    IF v_cost <> 14950 THEN
        RAISE EXCEPTION 'FIXTURE 77B 失败:合计应为 13000 + 650 + 1300 = 14950,实得 %', v_cost;
    END IF;
    -- 【明细三行,而且各带各的汇率】—— 合计对了不等于明细对了:一个把所有行都
    -- 按同一个汇率记的实现,合计照样可能凑对,而"这个数怎么来的"就答错了。
    IF (SELECT count(*) FROM fixed_asset_cost_entries WHERE asset_id = v_asset) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 77B 失败:成本明细应当三行';
    END IF;
    IF (SELECT count(DISTINCT currency) FROM fixed_asset_cost_entries WHERE asset_id = v_asset) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 77B 失败:三笔里应当有两种原币(USD 机器 + SGD 运费)';
    END IF;
    IF (SELECT round(SUM(amount_base), 2) FROM fixed_asset_cost_entries WHERE asset_id = v_asset) <> v_cost THEN
        RAISE EXCEPTION 'FIXTURE 77B 失败:明细合计应当等于表头的 cost_base —— 两个数一旦对不上,审计要问的正是这一句';
    END IF;

    -- ══════════ C. 追加的三条拒绝,各自只差它自己那一件 ═══════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_expense('2028-03-13', '1500', 1, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', gen_random_uuid()));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'ASSET_NOT_FOUND|%' THEN
        RAISE EXCEPTION 'FIXTURE 77C 失败:不存在的资产应当按名拒,实得 %', COALESCE(v_msg,'(记进去了)');
    END IF;

    -- 【1500 ↔ p_asset 的互相要求一字未改 —— 追加模式没有削弱它】
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_expense('2028-03-13', '6300', 1, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'ASSET_REQUIRES_CAPITAL_ACCOUNT|%' THEN
        RAISE EXCEPTION 'FIXTURE 77C 失败:资本标记只有 1500 一个落点,追加模式也不例外,实得 %',
            COALESCE(v_msg,'(记进去了)');
    END IF;

    -- ══════════ D. 投用:冻结成本,折旧从那一天起算 ═══════════════════════════
    -- 投用日 3/16,三月 31 天 → 首月按天:14950/100 × 16/31 = 77.16…
    v_r := set_asset_in_service(v_asset, '2028-03-16');
    IF (v_r->>'in_service_date') <> '2028-03-16' THEN
        RAISE EXCEPTION 'FIXTURE 77D 失败:投用日应当写进去,实得 %', v_r::text;
    END IF;

    -- 投用之后不许再追加 —— 这一条是本刀的第三个决定
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_expense('2028-03-20', '1500', 500, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'ASSET_ALREADY_IN_SERVICE|%' THEN
        RAISE EXCEPTION 'FIXTURE 77D 失败:投用之后不该再追加成本(那会让已提的各期全错),实得 %',
            COALESCE(v_msg,'(加进去了)');
    END IF;
    IF (SELECT cost_base FROM fixed_assets WHERE id = v_asset) <> 14950 THEN
        RAISE EXCEPTION 'FIXTURE 77D 失败:被拒的追加不该改动成本';
    END IF;
    -- 投用只发生一次
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_asset_in_service(v_asset, '2028-03-20');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'ASSET_ALREADY_IN_SERVICE|%' THEN
        RAISE EXCEPTION 'FIXTURE 77D 失败:投用日不该改第二次(改它等于推翻已提的折旧),实得 %',
            COALESCE(v_msg,'(改了)');
    END IF;
    -- 早于购置日按名拒(表上那条 CHECK 也拦得住,但它给的是约束名)
    v_r := record_expense('2028-04-02', '1500', 100, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('description', 'Fixture spare 77', 'useful_life_months', 50));
    v_asset2 := (v_r->>'asset_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_asset_in_service(v_asset2, '2028-04-01');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'IN_SERVICE_BEFORE_ACQUISITION|%' THEN
        RAISE EXCEPTION 'FIXTURE 77D 失败:投用日早于购置日应当按名拒,实得 %', COALESCE(v_msg,'(设进去了)');
    END IF;

    -- 折旧:从【投用日】起算,首月按天(FIN-22 的约定,fixture 16 也钉着)
    v_r := depreciate_fixed_assets('2028-03-31');
    SELECT COALESCE(SUM(amount_base), 0) INTO v_dep FROM fixed_asset_depreciation WHERE asset_id = v_asset;
    IF v_dep <> round(14950::numeric / 100 * 16 / 31, 2) THEN
        RAISE EXCEPTION 'FIXTURE 77D 失败:首月应提 = 14950/100 × 16/31 = %,实得 %(从购置日起算会是 149.50 —— 两种实现差得开)',
            round(14950::numeric / 100 * 16 / 31, 2), v_dep;
    END IF;

    -- ══════════ E. 锁的那道闸:三态 ═════════════════════════════════════════
    -- ① 欠着 → 点名拒,并说出金额(4 月还没提)
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM close_period('2028-04-30', 'fixture 77');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'DEPRECIATION_OUTSTANDING|2028-04-30|%' THEN
        RAISE EXCEPTION 'FIXTURE 77E 失败:折旧还欠着时不该锁得进去 —— 锁上之后 PERIOD_LOCKED 会让它补都补不回来。实得 %',
            COALESCE(v_msg,'(锁进去了)');
    END IF;

    -- ② 提完了(差额 0)→ 放行
    PERFORM depreciate_fixed_assets('2028-04-30');
    v_r := close_period('2028-04-30', 'fixture 77');
    IF (v_r->>'locked_before') <> '2028-05-01' THEN
        RAISE EXCEPTION 'FIXTURE 77E 失败:折旧提完之后应当锁得进去,实得 %', v_r::text;
    END IF;

    -- ③ 根本没有资产 → 放行(na,与月结中枢那三态口径一致)
    UPDATE finance_settings SET locked_before = NULL;
    DELETE FROM fixed_asset_depreciation;
    DELETE FROM fixed_asset_cost_entries;
    DELETE FROM fixed_assets;
    v_r := close_period('2028-05-31', 'fixture 77 no assets');
    IF (v_r->>'locked_before') <> '2028-06-01' THEN
        RAISE EXCEPTION 'FIXTURE 77E 失败:一台资产都没有时,这道闸不该拦,实得 %', v_r::text;
    END IF;
    UPDATE finance_settings SET locked_before = NULL;

    -- ══════════ 注入 1:摘掉锁那道闸 ═══════════════════════════════════════
    -- 【这道闸没有第二层】表上没有任何东西阻止一个欠着折旧的月份被锁进去 ——
    -- 它漏了就是真的锁得进去,而那正是 FA-0 之前的状态。
    -- 重造一台欠着折旧的资产,注入之后 close_period 必须【成功】。
    v_r := record_expense('2028-06-01', '1500', 1200, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('description', 'Fixture inj 77', 'useful_life_months', 12,
                           'in_service_date', '2028-06-01'));
    v_asset2 := (v_r->>'asset_id')::uuid;
    IF (preview_depreciate_fixed_assets('2028-06-30')->>'total_delta')::numeric <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 77 注入1 前提不成立:要的是一个【折旧还欠着】的月份';
    END IF;

    v_inj := regexp_replace(def_close,
        'v_dep := \(preview_depreciate_fixed_assets\(p_period_end\)->>''total_delta''\)::numeric;\s*IF COALESCE\(v_dep, 0\) > 0 THEN\s*RAISE EXCEPTION ''DEPRECIATION_OUTSTANDING\|%\|%'', p_period_end, v_dep;\s*END IF;',
        '');
    IF v_inj = def_close THEN
        RAISE EXCEPTION 'FIXTURE 77 注入1 失败:在 close_period 里没找到那道闸的原文 —— 这个注入什么也没删,下面那句"应当锁得进去"会变成空转';
    END IF;
    EXECUTE v_inj;
    v_r := close_period('2028-06-30', 'fixture 77 injection');
    IF (v_r->>'locked_before') <> '2028-07-01' THEN
        RAISE EXCEPTION 'FIXTURE 77 注入1 失败:摘掉那道闸之后,欠着折旧的月份应当【锁得进去】—— 说明 E 臂①拒它的不是那道闸';
    END IF;
    UPDATE finance_settings SET locked_before = NULL;

    -- ══════════ 注入 2:摘掉"投用之后不许追加"那道门 ═════════════════════════
    -- 同样没有第二层:表上没有任何约束阻止 cost_base 在投用之后变大。
    v_inj := regexp_replace(def_rec,
        'IF v_target\.in_service_date IS NOT NULL THEN\s*RAISE EXCEPTION ''ASSET_ALREADY_IN_SERVICE\|%\|%'', v_target\.code, v_target\.in_service_date;\s*END IF;',
        '');
    IF v_inj = def_rec THEN
        RAISE EXCEPTION 'FIXTURE 77 注入2 失败:在 record_expense 里没找到【投用即冻结】那道门的原文 —— 这个注入什么也没删';
    END IF;
    EXECUTE v_inj;
    SELECT cost_base INTO v_cost FROM fixed_assets WHERE id = v_asset2;
    PERFORM record_expense('2028-06-20', '1500', 300, 'SGD', NULL, 'unpaid', NULL, v_sup, NULL, NULL,
        jsonb_build_object('asset_id', v_asset2));
    IF (SELECT cost_base FROM fixed_assets WHERE id = v_asset2) <> v_cost + 300 THEN
        RAISE EXCEPTION 'FIXTURE 77 注入2 失败:摘掉那道门之后,投用后的追加应当【真的加进去】—— 说明 D 臂拒它的不是那道门';
    END IF;
END $$;
ROLLBACK;
