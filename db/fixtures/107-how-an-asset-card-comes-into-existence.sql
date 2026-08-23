-- 107 一张资产卡怎么诞生 —— 两扇门,一个号段,而设备链终于起得了步
--
-- 【这份 fixture 自带全部数据】重建库里没有任何业务数据(线上 fixed_assets 也是
-- 0 行)。每一臂自己造供应商 / 资产卡 / 采购单 / 支出,【不从别处借】,也不吃别的
-- 臂留下的状态(README 第 2 条)。
--
-- 【每一臂建什么、钉什么】
-- F1 前提,先于一切派生量:record_expense 的【新建模式】一个字没变 ——
--    建:供应商 + 一笔 1500 资本支出。钉:卡建出来了、成本就是那笔金额、
--    出生凭证 expense_id 指着那笔支出、成本明细恰好 1 条。
--    本刀动了 record_expense 的取号那几行,所以"另一扇门照旧"必须先证明。
-- F2 本刀存在的理由 —— 【整条顺序】跑通:
--    建:供应商 + create_fixed_asset 的零成本卡 + 设备采购单 + 定金 + 发票。
--    卡 → 设备行 → 定金 → 发票(挂在那条行上)→ 成本落到卡上。
--    这一臂若写不出来,这条链就还是起不了步,本刀也就没有意义。
--    顺带钉【两扇门共用一个号段】:两张卡的号必须是同一年里连续的两个。
-- F3 D3 是一个【铰链】,不是一堵墙,两半都要:
--    (a) 零成本卡投用不了 → 按名拒 ASSET_HAS_NO_COST;
--    (b) 成本落上来之后,同一张卡投得了用。
--    只有 (a) 就只证明了"这张卡什么都干不了"。
-- F3b 同一条规矩的另一半(grill 加的):零成本卡【处置不了】,同样按名拒。
--    不加这一条,本刀就自己造出了一条通向【裸 23514】的路 ——
--    dispose 无条件按 cost_base 发一条 1500 贷方,而 journal_lines 要求 amount_ccy > 0。
-- F4 create_fixed_asset 的每一条拒绝,逐条按名。
--
-- 【为什么每一臂都自己建供应商/卡】共享可变状态的用例会因为错的理由通过:
-- 一张卡被上一臂投用过之后,下一臂对它的"拒绝"可能只是因为它已经投用了。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text;
    v_sup uuid;
    v_res jsonb; v_exp uuid;
    v_a1 uuid; v_a2 uuid; v_a3 uuid;
    v_code1 text; v_code2 text;
    v_po uuid; v_line uuid;
    v_cost numeric; v_n int; v_ins date; v_link uuid; v_expid uuid;
    v_msg text; v_denied boolean;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-107', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX107-S', 'fixture 107 supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;

    -- ══════════ F1 · 新建模式照旧(前提)═══════════════════════════════════
    RAISE NOTICE 'fixture 107 · 进入 F1';
    v_res := record_expense(DATE '2026-01-05', '1500', 40000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 107 outright machine',
        jsonb_build_object('description', 'fixture 107 outright', 'useful_life_months', 60), NULL);
    v_exp := (v_res->>'expense_id')::uuid;
    SELECT id, code, cost_base, expense_id INTO v_a1, v_code1, v_cost, v_expid
      FROM fixed_assets WHERE expense_id = v_exp;
    IF v_a1 IS NULL OR v_cost <> 40000 OR v_expid IS DISTINCT FROM v_exp THEN
        RAISE EXCEPTION 'FIXTURE 107F1 失败:新建模式应当照旧建出一张【带着成本与出生凭证】的卡(成本 40,000),实得 asset=% cost=% expense_id=% —— 本刀动了这支的取号,若它坏了,后面每一条都不必再看',
            COALESCE(v_a1::text,'(null)'), COALESCE(v_cost::text,'(null)'), COALESCE(v_expid::text,'(null)');
    END IF;
    SELECT count(*) INTO v_n FROM fixed_asset_cost_entries WHERE asset_id = v_a1;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 107F1 失败:新建模式应当同时写下第一条成本明细,实得 % 条', v_n;
    END IF;

    -- ══════════ F2 · 整条顺序:卡 → 设备行 → 定金 → 发票 → 成本 ═════════════
    RAISE NOTICE 'fixture 107 · 进入 F2';
    v_res := create_fixed_asset('fixture 107 press', 120, DATE '2026-01-06');
    v_a2 := (v_res->>'asset_id')::uuid;
    v_code2 := v_res->>'code';

    SELECT cost_base, in_service_date, expense_id INTO v_cost, v_ins, v_expid
      FROM fixed_assets WHERE id = v_a2;
    IF v_cost <> 0 OR v_ins IS NOT NULL OR v_expid IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 107F2 失败:新门建出来的卡应当是【零成本、未投用、无出生凭证】,实得 cost=% in_service=% expense_id=%',
            v_cost, COALESCE(v_ins::text,'(null)'), COALESCE(v_expid::text,'(null)');
    END IF;
    SELECT count(*) INTO v_n FROM fixed_asset_cost_entries WHERE asset_id = v_a2;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 107F2 失败:零成本的卡应当【一条成本明细都没有】,实得 % 条 —— 全库没有任何地方假设资产至少有一条明细(两处求和都 COALESCE 到 0),这一条把那个前提钉住', v_n;
    END IF;

    -- 【两扇门,一个号段】F1 与 F2 的卡同年建出,号必须是连续的两个。
    -- 两份各自实现的取号逻辑今天一致、明天未必 —— 这一条就是在钉那件事。
    -- 【年份从第一张卡自己身上取,不写死】此处原本写死 'FA-2027-' —— 那是一个
    -- 与取号年份耦合的字面量,而取号年份来自购置日。FIX-1 把这一支的日期整体
    -- 平移进过去之后它当场就错了,**而它本来就是一颗定时炸弹**:换一年建卡就红。
    IF v_code2 <> split_part(v_code1,'-',1) || '-' || split_part(v_code1,'-',2) || '-'
                  || LPAD((split_part(v_code1,'-',3)::integer + 1)::text, 4, '0') THEN
        RAISE EXCEPTION 'FIXTURE 107F2 失败:两扇门必须共用一个号段 —— 第一张 %,第二张应当是它的下一号,实得 %',
            v_code1, v_code2;
    END IF;

    -- 卡 → 设备采购单行(EQP-1a:行引用一张【已存在】的卡)
    v_res := create_purchase_order(v_sup, DATE '2026-01-10', DATE '2026-04-01', v_ccy, NULL,
        NULL, NULL, 'fixture 107 equipment PO',
        jsonb_build_array(jsonb_build_object('asset_id', v_a2, 'quantity', 1,
                                             'estimated_unit_price', 100000)));
    v_po := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    IF v_line IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 107F2 失败:零成本卡应当挂得上设备采购行 —— 这正是本刀要解决的那个顺序问题';
    END IF;

    -- 定金 30,000(进 1300 预付款项)
    PERFORM record_payment('out', v_sup, 30000, v_ccy, NULL, NULL, DATE '2026-01-15',
        'fixture 107 deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', v_po, 'amount_doc', 30000)),
        'supplier');

    -- 发票 100,000,挂在【那条设备行】上,追加模式落到【那张卡】上
    v_res := record_expense(DATE '2026-03-01', '1500', 100000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 107 machine invoice',
        jsonb_build_object('asset_id', v_a2), NULL, v_line);
    v_exp := (v_res->>'expense_id')::uuid;

    -- 定金冲抵到那张发票上
    -- EQP-1c-b(X1):冲抵日现在【必填】—— 它决定这笔分录落在哪个期间。
    PERFORM apply_prepayment(v_po, NULL, 30000, 'fixture 107 release', v_exp, DATE '2026-03-05');

    SELECT purchase_order_line_id INTO v_link FROM expenses WHERE id = v_exp;
    IF v_link IS DISTINCT FROM v_line THEN
        RAISE EXCEPTION 'FIXTURE 107F2 失败:发票应当挂在那条设备行上,实得 %', COALESCE(v_link::text,'(null)');
    END IF;
    SELECT cost_base, expense_id INTO v_cost, v_expid FROM fixed_assets WHERE id = v_a2;
    IF v_cost <> 100000 THEN
        RAISE EXCEPTION 'FIXTURE 107F2 失败:成本应当落到卡上(100,000),实得 %', v_cost;
    END IF;
    -- 【出生凭证仍然为空,而这是对的】追加不改 expense_id ——
    -- 那一列记的是"谁生出了这张卡",而这张卡不是任何一笔支出生出来的。
    IF v_expid IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 107F2 失败:追加成本【不该】回填出生凭证,实得 % —— expense_id 记的是"谁生出了这张卡",不是"谁付了钱"', v_expid;
    END IF;
    SELECT count(*) INTO v_n FROM fixed_asset_cost_entries WHERE asset_id = v_a2;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 107F2 失败:成本明细应当恰好 1 条(那张发票),实得 %', v_n;
    END IF;

    -- ══════════ F3 · 铰链:零成本投不了用,有成本就投得了 ════════════════════
    RAISE NOTICE 'fixture 107 · 进入 F3';
    -- (a) 自己建一张零成本卡 —— 不借 F2 那张(它已经有成本了)
    v_res := create_fixed_asset('fixture 107 not yet paid', 60, DATE '2026-02-01');
    v_a3 := (v_res->>'asset_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_asset_in_service(v_a3, DATE '2026-02-10');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('ASSET_HAS_NO_COST' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 107F3a 失败:零成本的卡不该投得了用,应按名拒 ASSET_HAS_NO_COST,实得 denied=% msg=% —— 放它过去不会报错,只会每期【安静地】提 0 元,看起来像一台在役资产',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- (b) 成本落上来之后,同一张卡投得了用
    PERFORM record_expense(DATE '2026-02-05', '1500', 7000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 107 late invoice',
        jsonb_build_object('asset_id', v_a3), NULL);
    PERFORM set_asset_in_service(v_a3, DATE '2026-02-10');
    SELECT in_service_date INTO v_ins FROM fixed_assets WHERE id = v_a3;
    IF v_ins <> DATE '2026-02-10' THEN
        RAISE EXCEPTION 'FIXTURE 107F3b 失败:成本落上来之后应当投得了用,实得 % —— 少了这一半,上一条就只证明了"这张卡什么都干不了"', COALESCE(v_ins::text,'(null)');
    END IF;

    -- ══════════ F3b · 同一条规矩:零成本卡处置不了 ══════════════════════════
    RAISE NOTICE 'fixture 107 · 进入 F3b';
    v_res := create_fixed_asset('fixture 107 never arrived', 60, DATE '2026-02-01');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM dispose_fixed_asset((v_res->>'asset_id')::uuid, DATE '2026-02-20', 0, NULL, 'fixture 107');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('ASSET_HAS_NO_COST' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 107F3b 失败:零成本的卡不构成一次处置,应按名拒 ASSET_HAS_NO_COST,实得 denied=% msg=% —— 若这里报的是 23514 / journal_lines_amount_ccy_check,说明那条无条件发出的 1500 贷方把一条裸的约束违例打到了人脸上',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;

    -- ══════════ F4 · create_fixed_asset 的每一条拒绝,逐条按名 ═══════════════
    RAISE NOTICE 'fixture 107 · 进入 F4';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_fixed_asset('   ', 60, DATE '2026-01-01');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('ASSET_DESCRIPTION_REQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 107F4 失败:只有空白的描述应被 ASSET_DESCRIPTION_REQUIRED 拒(btrim 之后为空),实得 denied=% msg=%', v_denied, COALESCE(v_msg,'(收下了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_fixed_asset('fixture 107 bad life', 0, DATE '2026-01-01');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('ASSET_LIFE_INVALID' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 107F4 失败:年限 0 应被 ASSET_LIFE_INVALID 拒,实得 denied=% msg=%', v_denied, COALESCE(v_msg,'(收下了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_fixed_asset('fixture 107 no date', 60, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('ASSET_ACQUISITION_DATE_REQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 107F4 失败:取得日缺失应被 ASSET_ACQUISITION_DATE_REQUIRED 拒(它是投用日的下界,悄悄填今天会把投用日的合法范围一起挪掉),实得 denied=% msg=%', v_denied, COALESCE(v_msg,'(收下了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM create_fixed_asset('fixture 107 bad cat', 60, DATE '2026-01-01', 'spaceship');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('ASSET_CATEGORY_INVALID' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 107F4 失败:不存在的分类应被 ASSET_CATEGORY_INVALID 按名拒(表上那条 CHECK 也拦得住,但它只给得出约束名),实得 denied=% msg=%', v_denied, COALESCE(v_msg,'(收下了)');
    END IF;

    RAISE NOTICE 'fixture 107:F1/F2/F3/F3b/F4 通过';
END $$;
ROLLBACK;
