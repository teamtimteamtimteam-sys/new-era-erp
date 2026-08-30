-- 150 COMM-1:佣金【说得出义务何时产生,不说就拒】,而敞口报表【说得出它看不见什么】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【六个点名要躲开的陷阱,逐条写出这一支是怎么躲的】
--
--  (a) **一条断言之所以过,是因为两份实现碰巧一致。**
--      D 臂不静态读一个状态,而是**逼它【翻】三次**:0 份合同 → 有合同没条款 →
--      有条款。一个不读数据的实现会卡在第一个状态上,当场红,
--      而且红在状态名上,不是红在措辞上。
--
--  (b) **一条目录断言命中的是注释里的一次提及。**
--      H 臂查 information_schema / pg_constraint / pg_class.relrowsecurity /
--      pg_proc.prosecdef —— **目录事实**,不 grep 源码。
--      而且**先断言该有的列在**,再断言不该有的列(计提那一半)不在 ——
--      否则"没有计提列"在一张【根本不存在的表】上也会通过。
--
--  (c) **一支 SECURITY DEFINER 函数没有权限检查。**
--      price_exposure_report **是** definer(H 臂按 prosecdef 断言),
--      所以 G 臂**真的换一个没有 module.finance.view 的角色去调它**,
--      断言按名拒;再补回权限断言放行 —— 证明那不是一条死路。
--
--  (d) **断言过了,是因为那个集合是空的。**
--      A/B/C 每一条拒绝旁边都配一条**会成功的**对照:
--      「拒了」与「这条路根本走不通」必须分得开。
--      D 臂的每一次翻转都断言**具体的状态名与具体的行数**,不是"非空"。
--
--  (e) **一个什么都没注入的注入,长得和一个通过了的注入一模一样。**
--      两处注入都**先断言注入真的改了东西**(定义/默认值确实变了),
--      改不动就当场报"这个注入什么也没删"。
--
--  (f) ★★【SETTLE-1 新添的那一条:一条断言【为真】,却对它宣称的那件事
--      【没有管辖权】】★★ —— 它测的是一个比名字更弱的性质,于是能扛过故障注入。
--      本支两处正面对付它:
--        · A 臂宣称的是「那一列**没有默认值**,所以不说就拒」。
--          光断言"插入失败"**管不住**这件事(列是 NOT NULL 就够失败了)。
--          所以注入①**真的给它加上一个 DEFAULT**,断言那条插入【当场变成成功】——
--          A 臂若只测到"NOT NULL",这个注入它是察觉不到的。
--        · E 臂宣称的是「采购侧永远印成一句话,不是一个 0」。
--          光断言 modelled = false **管不住**它会不会顺手报一个 0 吨。
--          所以 E3 断言 purchase_side 底下**根本没有任何数值型的键**,
--          注入②再把 modelled 翻成 true,断言 E1 当场红。
--
-- 【本 fixture 钉住的东西】
--   A ★★ recognition_trigger 【没有默认值】—— 不说就拒,说了就过 ★★
--   B 代理人必须是 service_vendor(按名拒;换成 service_vendor 就放行)
--   C 计费口径与格子必须对得上(百分比不许带金额,按吨不许带费率)
--   D ★★ 敞口报表的三种状态,由【翻转】证明,不由静态读证明 ★★
--   E ★★ 采购侧【永远】是一句话,不是一个 0;而且在卖方向有数据时也仍然是 ★★
--   F 开市日历是【另一个】原因 —— 它与"没有合同"不会塌成一件事
--   G 权限【按名】拒,补回权限就放行
--   H 目录事实(含那个【刻意的缺席】:没有计提那一列)
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    v_user      uuid := gen_random_uuid();
    v_user_nof  uuid := gen_random_uuid();
    r_all       uuid;
    r_nofin     uuid;
    v_vendor    uuid;
    v_goods     uuid;
    v_cust      uuid;
    v_con       uuid;
    v_id        uuid;
    v_r         jsonb;
    v_denied    boolean; v_msg text;
    v_n         integer;
    v_def       text; v_inj text;
    v_numkeys   integer;
BEGIN
    -- ══════════ 角色:一个全权,一个【独独没有 module.finance.view】 ══════════
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-150', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-150-nofin', 'f', 'f', true) RETURNING id INTO r_nofin;
    INSERT INTO role_permissions (role_id, permission_code)
        SELECT r_nofin, code FROM permissions WHERE code <> 'module.finance.view';
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user_nof, r_nofin);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ 两家对手方:一家服务商(合法的代理人)、一家卖货的 ══════════
    -- 【supplies_goods 是【生成列】,不许显式写】—— 它由 counterparty_type 推出来。
    INSERT INTO suppliers (code, legal_name, country, supplier_types, counterparty_type)
    VALUES ('F150-AGENT', 'Fixture 150 Agent', 'SG', ARRAY['trader'], 'service_vendor')
    RETURNING id INTO v_vendor;
    INSERT INTO suppliers (code, legal_name, country, supplier_types, counterparty_type)
    VALUES ('F150-GOODS', 'Fixture 150 Goods', 'SG', ARRAY['recycler'], 'goods_supplier')
    RETURNING id INTO v_goods;

    -- ══════════ A ★★ recognition_trigger:不说就拒,说了就过 ★★ ══════════════
    -- 【(d) 对照先行】先证明这条路【走得通】—— 否则下面那条"拒了"什么都不证明。
    INSERT INTO commission_agreements
        (agent_supplier_id, side, basis, rate_pct, recognition_trigger, valid_from, valid_to)
    VALUES (v_vendor, 'sale', 'percentage_of_value', 2.5, 'on_invoice',
            DATE '2026-01-01', DATE '2026-12-31')
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 150A 失败:一份说清了触发点的协议应当建得起来 —— 建不起来的话,下面那条拒绝证明不了任何事'; END IF;

    -- ★ 不说触发点 → 必须拒
    v_denied := false;
    BEGIN
        INSERT INTO commission_agreements
            (agent_supplier_id, side, basis, rate_pct, valid_from, valid_to)
        VALUES (v_vendor, 'sale', 'percentage_of_value', 2.5,
                DATE '2026-01-01', DATE '2026-12-31');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 150A 失败:★ 没有说义务何时产生,却被收下了 ★ —— 那一列是刻意没有默认值的,系统不许替人选一个商业立场'; END IF;
    IF v_msg NOT LIKE '%recognition_trigger%' THEN
        RAISE EXCEPTION 'FIXTURE 150A 失败:拒是拒了,但拒的不是 recognition_trigger(实得:%)—— 一条拒错了东西的断言比不拒更坏', v_msg; END IF;

    -- ══════════ B 代理人必须是 service_vendor ══════════════════════════════
    v_denied := false;
    BEGIN
        INSERT INTO commission_agreements
            (agent_supplier_id, side, basis, rate_pct, recognition_trigger, valid_from, valid_to)
        VALUES (v_goods, 'purchase', 'percentage_of_value', 1.0, 'on_shipment',
                DATE '2026-01-01', DATE '2026-12-31');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 150B 失败:一家【卖货给我们的】供应商被当成了代理人 —— 佣金的收款方是提供服务的第三方'; END IF;
    IF v_msg NOT LIKE '%COMMISSION_AGENT_NOT_SERVICE_VENDOR%' THEN
        RAISE EXCEPTION 'FIXTURE 150B 失败:拒了,但不是那条具名拒绝(实得:%)', v_msg; END IF;

    -- ══════════ C 口径与格子必须对得上 ══════════════════════════════════════
    -- C1:百分比却带着金额与币种 → 拒
    v_denied := false;
    BEGIN
        INSERT INTO commission_agreements
            (agent_supplier_id, side, basis, rate_pct, amount_ccy, currency,
             recognition_trigger, valid_from, valid_to)
        VALUES (v_vendor, 'sale', 'percentage_of_value', 2.0, 5000,
                (SELECT code FROM currencies WHERE is_base LIMIT 1),
                'on_invoice', DATE '2026-01-01', DATE '2026-12-31');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 150C1 失败:一行同时写着百分比和金额被收下了 —— 没有人分得出哪一个算数'; END IF;

    -- C2:按吨却填费率 → 拒
    v_denied := false;
    BEGIN
        INSERT INTO commission_agreements
            (agent_supplier_id, side, basis, rate_pct, recognition_trigger, valid_from, valid_to)
        VALUES (v_vendor, 'purchase', 'per_tonne', 3.0, 'on_shipment',
                DATE '2026-01-01', DATE '2026-12-31');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 150C2 失败:按吨的协议填了费率却被收下了'; END IF;

    -- C3【对照】:按吨 + 金额 + 币种 → 应当成功(否则 C1/C2 只是"这条路走不通")
    INSERT INTO commission_agreements
        (agent_supplier_id, side, basis, amount_ccy, currency,
         recognition_trigger, valid_from, valid_to)
    VALUES (v_vendor, 'free_standing', 'per_tonne', 12.5,
            (SELECT code FROM currencies WHERE is_base LIMIT 1),
            'on_counterparty_payment', DATE '2026-01-01', DATE '2026-12-31');

    -- ══════════ D ★★ 敞口报表的三种状态 —— 由【翻转】证明 ★★ ═══════════════
    -- 【为什么是翻转不是静态读】一个根本不读数据的实现,静态读时也可能"碰巧对"。
    -- 逼它翻三次,它就再也碰不了巧。

    -- D0:一份合同都没有 → 【不是"敞口为零"】,是"问题还没有主语"
    DELETE FROM contract_pricing_terms;
    DELETE FROM contracts;
    v_r := price_exposure_report();
    IF v_r->'sell_side'->>'state' <> 'no_contracts' THEN
        RAISE EXCEPTION 'FIXTURE 150D0 失败:零份合同时状态应当是 no_contracts,实得 %', v_r->'sell_side'->>'state'; END IF;
    IF (v_r->'coverage'->>'contracts_total')::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 150D0 失败:分母没有跟着说话'; END IF;

    -- D1:有合同、但没有一份写了计价条款 → 状态【必须翻】
    INSERT INTO customers (code, legal_name, country)
    VALUES ('F150-CUST', 'Fixture 150 Customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO contracts (code, customer_id, kind, title, effective_from, status)
    VALUES ('F150-CON', v_cust, 'offtake', 'Fixture 150 offtake', DATE '2026-01-01', 'active')
    RETURNING id INTO v_con;

    v_r := price_exposure_report();
    IF v_r->'sell_side'->>'state' <> 'no_pricing_terms' THEN
        RAISE EXCEPTION 'FIXTURE 150D1 失败:有合同没条款时状态应当翻成 no_pricing_terms,实得 % —— 状态不翻,说明这份报告没有在读数据', v_r->'sell_side'->>'state'; END IF;
    IF (v_r->'coverage'->>'contracts_total')::int <> 1
       OR (v_r->'coverage'->>'contracts_sell_side')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 150D1 失败:分母没有跟着翻(total=%,sell=%)',
            v_r->'coverage'->>'contracts_total', v_r->'coverage'->>'contracts_sell_side'; END IF;

    -- D2:写了一条计价条款 → 状态【必须再翻】,而且列出正好一行头寸
    INSERT INTO contract_pricing_terms
        (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (v_con, 'ni', 'shipment', 1, 'LME', 90);

    v_r := price_exposure_report();
    IF v_r->'sell_side'->>'state' <> 'open_positions_listed' THEN
        RAISE EXCEPTION 'FIXTURE 150D2 失败:有条款时状态应当翻成 open_positions_listed,实得 %', v_r->'sell_side'->>'state'; END IF;
    IF jsonb_array_length(v_r->'sell_side'->'positions') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 150D2 失败:应当正好列出 1 条头寸,实得 %',
            jsonb_array_length(v_r->'sell_side'->'positions'); END IF;
    IF (v_r->'coverage'->>'contracts_with_pricing_terms')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 150D2 失败:分母里"写了条款的合同"没有跟着翻'; END IF;

    -- ══════════ E ★★ 采购侧永远是一句话,不是一个 0 ★★ ══════════════════════
    -- 【注意这一臂跑在 D2 【之后】】—— 也就是卖方向【已经有数据】的时候。
    -- 一个"数据一来就把缺席悄悄改口"的实现,在这里必定红。
    IF (v_r->'purchase_side'->>'modelled')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 150E1 失败:★ 采购侧被标成"已建模" ★ —— PRICE-1 只做了卖方向,§9 至今没有人回答'; END IF;
    IF length(COALESCE(v_r->'purchase_side'->>'why','')) < 100 THEN
        RAISE EXCEPTION 'FIXTURE 150E2 失败:采购侧那句话太短,撑不起一句解释(实得 % 字符)',
            length(COALESCE(v_r->'purchase_side'->>'why','')); END IF;

    -- ★★ E3(陷阱 f):purchase_side 底下【不许有任何数值型的键】★★
    --   「modelled = false」管不住它顺手报一个 0 吨,而 0 吨正是本刀要消灭的那个答案。
    SELECT count(*) INTO v_numkeys
      FROM jsonb_each(v_r->'purchase_side') e
     WHERE jsonb_typeof(e.value) = 'number';
    IF v_numkeys <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 150E3 失败:★ 采购侧报出了 % 个【数字】★ —— 它只许说一句话。一个 0 的意思是"我们没这样买过",而真相是这套系统还不记这件事', v_numkeys; END IF;

    -- ══════════ F 开市日历是【另一个】原因,不与"没有合同"塌成一件事 ═════════
    -- 此刻合同与条款都在(D2 之后),日历仍然是空的 —— 两件事必须各说各的。
    IF (v_r->'quotational_period'->>'average_available')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 150F0 失败:一天日历都没有,却说均价算得出来'; END IF;
    IF (v_r->'quotational_period'->>'calendar_days_loaded')::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 150F0 失败:日历分母不对'; END IF;

    -- 加载交易日 → 这一条【必须翻】,而卖方向的状态【不许跟着动】
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note)
    VALUES ('LME', DATE '2026-09-01', true, 'fixture 150'),
           ('LME', DATE '2026-09-02', true, 'fixture 150');
    v_r := price_exposure_report();
    IF (v_r->'quotational_period'->>'average_available')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 150F1 失败:加载了交易日之后,那一条没有翻 —— 说明它没在读日历'; END IF;
    IF v_r->'sell_side'->>'state' <> 'open_positions_listed' THEN
        RAISE EXCEPTION 'FIXTURE 150F1 失败:日历变了却把卖方向的状态也带动了 —— 两个原因塌成了一件事'; END IF;

    -- ══════════ G 权限:按名拒,补回就放行 ══════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user_nof), true);
    v_denied := false;
    BEGIN PERFORM price_exposure_report();
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 150G 失败:★ 一个没有 module.finance.view 的人读到了价格敞口 ★ —— 它是 SECURITY DEFINER,属主权限绕过 RLS,所以那句权限检查不是礼节'; END IF;

    -- 补回权限 → 必须放行(证明那不是一条死路)
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_nofin, 'module.finance.view');
    v_r := price_exposure_report();
    IF v_r->'sell_side'->>'state' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 150G 失败:补回权限之后仍然读不出报告 —— 那条拒绝是一条死路,不是一道门'; END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ H 目录事实(先证该有的在,再证该缺的缺 —— 陷阱 b)═══════════
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='commission_agreements'
                      AND column_name='recognition_trigger') THEN
        RAISE EXCEPTION 'FIXTURE 150H 失败:recognition_trigger 这一列不在 —— 下面每一条断言都会在一张空表上白过'; END IF;
    -- ★ 那一列【必须没有默认值】,而且必须 NOT NULL
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='public' AND table_name='commission_agreements'
                  AND column_name='recognition_trigger'
                  AND (column_default IS NOT NULL OR is_nullable <> 'NO')) THEN
        RAISE EXCEPTION 'FIXTURE 150H 失败:★ recognition_trigger 有了默认值或变得可空 ★ —— 那一列的全部意思就是"不说就拒"'; END IF;
    -- 三条约束按名在
    IF (SELECT count(*) FROM pg_constraint
         WHERE conrelid='public.commission_agreements'::regclass
           AND conname IN ('commission_agreements_basis_fields','commission_agreements_validity_order')) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 150H 失败:两条具名 CHECK 不齐'; END IF;
    -- RLS 开着
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.commission_agreements'::regclass) THEN
        RAISE EXCEPTION 'FIXTURE 150H 失败:commission_agreements 没有开 RLS'; END IF;
    -- 报告是 SECURITY DEFINER(所以 G 臂那句权限检查才是必需的)
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid='public.price_exposure_report()'::regprocedure) THEN
        RAISE EXCEPTION 'FIXTURE 150H 失败:price_exposure_report 不是 SECURITY DEFINER —— G 臂守的东西变了'; END IF;
    -- ★【刻意的缺席】计提那一半没有建:表上不许长出一个"算出来的金额"列
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='public' AND table_name='commission_agreements'
                  AND column_name IN ('accrued_amount','accrual_amount','computed_amount','amount_due')) THEN
        RAISE EXCEPTION 'FIXTURE 150H 失败:表上长出了一个"算出来的金额"列 —— 计提那一半是 COMM-ACCRUAL-1,本刀刻意没做;一笔佣金都没付过,公式会被拟合到零个案例上'; END IF;

    -- ══════════ 注入① ★★ 陷阱 (f):A 臂到底有没有管辖权 ★★ ═════════════════
    -- A 臂宣称的是「那一列**没有默认值**」。光"插入失败"管不住这件事 ——
    -- NOT NULL 自己就够让它失败了。所以:**真的给它加一个默认值**,
    -- 断言那条本该被拒的插入【当场变成成功】。
    -- A 臂若只测到 NOT NULL,这个注入它察觉不到,而那正是要证伪的。
    ALTER TABLE commission_agreements ALTER COLUMN recognition_trigger SET DEFAULT 'on_invoice';
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='commission_agreements'
                      AND column_name='recognition_trigger' AND column_default IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 150 注入① 失败:默认值没加上 —— 这个注入什么也没改'; END IF;
    v_denied := false;
    BEGIN
        INSERT INTO commission_agreements
            (agent_supplier_id, side, basis, rate_pct, valid_from, valid_to)
        VALUES (v_vendor, 'sale', 'percentage_of_value', 9.9,
                DATE '2026-01-01', DATE '2026-12-31');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 150 注入① 失败:加了默认值之后那条插入【仍然被拒】—— 说明 A 臂拒的不是"没有默认值"这件事,它测的是一个比名字更弱的性质'; END IF;
    -- 放回去,并断言它又拒(否则"放回去了"只是一句话)
    ALTER TABLE commission_agreements ALTER COLUMN recognition_trigger DROP DEFAULT;
    v_denied := false;
    BEGIN
        INSERT INTO commission_agreements
            (agent_supplier_id, side, basis, rate_pct, valid_from, valid_to)
        VALUES (v_vendor, 'sale', 'percentage_of_value', 8.8,
                DATE '2026-01-01', DATE '2026-12-31');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 150 注入① 失败:撤掉默认值之后应当又拒'; END IF;

    -- ══════════ 注入② ★★ E 臂到底有没有管辖权 ★★ ═══════════════════════════
    -- 把 purchase_side.modelled 翻成 true,断言 E1 当场红。
    v_def := pg_get_functiondef('public.price_exposure_report()'::regprocedure);
    v_inj := replace(v_def, '''modelled'', false', '''modelled'', true');
    IF v_inj = v_def THEN
        RAISE EXCEPTION 'FIXTURE 150 注入② 失败:没找到 modelled=false 那一句 —— 这个注入什么也没改'; END IF;
    EXECUTE v_inj;
    v_r := price_exposure_report();
    IF (v_r->'purchase_side'->>'modelled')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 150 注入② 失败:注入之后 modelled 应当变成 true —— 说明 E1 断的不是这个字段'; END IF;
    EXECUTE v_def;   -- 放回去
    v_r := price_exposure_report();
    IF (v_r->'purchase_side'->>'modelled')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 150 注入② 失败:恢复定义之后 modelled 应当又是 false'; END IF;
END $$;
ROLLBACK;
