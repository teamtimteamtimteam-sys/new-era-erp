-- 106 冲销一笔资本支出,成本要一起退回去 —— 而"已投用"是一个铰链,不是一堵墙
--
-- 【这份 fixture 自带全部数据】重建库里没有任何业务数据(线上 fixed_assets 也是
-- 0 行)。每一臂自己造供应商 / 员工 / 资产卡 / 支出,【不从别处借】,也不吃别的
-- 臂留下的状态 —— 共享可变状态的用例会因为错的理由通过(README 第 2 条)。
--
-- 【每一臂建什么、钉什么】
-- F1 前提,先于一切派生量:一笔【普通(非资本)】支出的冲销,逐字照旧。
--    建:供应商 + 一笔 6xxx 挂账支出。钉:原单转 reversed、镜像单在册、
--    镜像挂着冲销分录、镜像【不】带核销行的那套形状一个字没变。
--    本刀重写了 reverse_expense 整个函数体,所以"没动到常态那条路"必须先证明。
-- F2 本刀的正题:建 供应商 + 资产卡(100,000)+ 追加(70,000),冲销那笔追加。
--    钉【两件,缺一不可】:表头回到 100,000,且【未冲销】明细恰好 1 条。
--    只钉表头 → 明细没被排除也能过;只钉明细 → 表头没退回也能过。
--    两个数由不同的代码路径产生,所以两条断言不是一条的复读。
-- F4 D2 是一个【铰链】,不是一堵墙 —— 两半都要,而且顺序相反才有说服力:
--    (a) 未投用 → 冲得掉(否则这一臂只证明了"什么都不许冲");
--    (b) 已投用 → 按名拒 ASSET_IN_SERVICE_COST_LOCKED。
--    两半各自建一台机器,不共用 —— 否则 (b) 可能只是因为 (a) 已经把钱冲走了。
-- F5 D3:建 员工 + 一笔【欠员工】的挂账支出,冲销它。
--    钉:冲得掉,且镜像单带着【同一个人】。本刀之前这里撞的是一条裸的
--    expenses_counterparty_shape 违例(docs/known-issues.md 记过,本刀退役它)。
--
-- 【不变量,写在这里因为三处都在用它】
--   fixed_assets.cost_base  ==  Σ fixed_asset_cost_entries.amount_base
--                               WHERE 它那笔支出 status = 'posted'
-- 左边是被 record_expense 逐笔累加维护的表头,右边是从明细现算的和 ——
-- 两侧由不同代码路径产生,所以它是一条【真的】检查(OPS-17 对自检提的那问:
-- "要怎样它们才会不相等?" —— 这里答得出来)。reverse_expense 自己也在退回
-- 成本之后当场核对它,对不上就抛 ASSET_COST_LEDGER_DIVERGED。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_exp_acct text;
    v_sup uuid; v_emp uuid;
    v_res jsonb; v_exp uuid; v_mirror uuid;
    v_asset uuid; v_asset2 uuid;
    v_status text; v_link uuid; v_emp_on_mirror uuid;
    v_cost numeric; v_sum numeric; v_n int;
    v_msg text; v_denied boolean; v_notes text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    SELECT code INTO v_exp_acct FROM accounts
     WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    -- 前提显式设定(README 第 5 条):期间锁是运行时状态,会随月结推进。
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-106', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX106-S', 'fixture 106 supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;

    -- ══════════ F1 · 普通支出的冲销,逐字照旧 ══════════════════════════════
    RAISE NOTICE 'fixture 106 · 进入 F1';
    v_res := record_expense(DATE '2026-01-05', v_exp_acct, 1234, v_ccy, NULL, 'unpaid',
        NULL, v_sup, NULL, 'fixture 106 ordinary expense', NULL, NULL);
    v_exp := (v_res->>'expense_id')::uuid;

    v_res := reverse_expense(v_exp, 'fixture 106 F1');
    v_mirror := (v_res->>'reversal_expense_id')::uuid;

    SELECT status INTO v_status FROM expenses WHERE id = v_exp;
    IF v_status <> 'reversed' THEN
        RAISE EXCEPTION 'FIXTURE 106F1 失败:普通支出冲销后原单应为 reversed,实得 % —— 本刀重写了整个函数体,常态那条路若已经坏了,后面每一条都不必再看', v_status;
    END IF;
    SELECT status, notes, journal_entry_id, reversed_by_expense
      INTO v_status, v_notes, v_link, v_emp_on_mirror
      FROM expenses WHERE id = v_mirror;
    IF v_status <> 'posted' OR v_notes NOT LIKE 'REVERSAL:%' OR v_link IS NULL
       OR v_emp_on_mirror IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 106F1 失败:镜像单应当是【在册的记录凭证】(status posted、notes 以 REVERSAL: 开头、挂着冲销分录、自己没有被冲),实得 status=% notes=% je=% reversed_by=%',
            v_status, COALESCE(v_notes,'(空)'), COALESCE(v_link::text,'(null)'), COALESCE(v_emp_on_mirror::text,'(null)');
    END IF;
    SELECT count(*) INTO v_n FROM expenses WHERE reversed_by_expense = v_mirror;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 106F1 失败:镜像单应当恰好被一张原单指着,实得 %', v_n;
    END IF;

    -- ══════════ F2 · 冲销一笔追加,成本退回去 ══════════════════════════════
    RAISE NOTICE 'fixture 106 · 进入 F2';
    -- 建卡 100,000(新建模式)
    v_res := record_expense(DATE '2026-01-05', '1500', 100000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 106 machine',
        jsonb_build_object('description', 'fixture 106 press', 'useful_life_months', 120), NULL);
    SELECT id INTO v_asset FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    IF v_asset IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 106F2 前提失败:资本支出没有生成资产卡';
    END IF;
    -- 追加 70,000
    v_res := record_expense(DATE '2026-02-05', '1500', 70000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 106 installation',
        jsonb_build_object('asset_id', v_asset), NULL);
    v_exp := (v_res->>'expense_id')::uuid;

    SELECT cost_base INTO v_cost FROM fixed_assets WHERE id = v_asset;
    IF v_cost <> 170000 THEN
        RAISE EXCEPTION 'FIXTURE 106F2 前提失败:追加之后成本应为 100,000 + 70,000 = 170,000,实得 %', v_cost;
    END IF;

    -- 冲销那笔追加
    PERFORM reverse_expense(v_exp, 'fixture 106 F2');

    -- 【断言一】表头退回去了
    SELECT cost_base INTO v_cost FROM fixed_assets WHERE id = v_asset;
    IF v_cost <> 100000 THEN
        RAISE EXCEPTION 'FIXTURE 106F2 失败:冲销那笔 70,000 之后成本应当回到 100,000(= 建卡那一笔),实得 % —— 这正是本刀存在的理由:分录冲掉了而台账没退,折旧读的是台账', v_cost;
    END IF;
    -- 【断言二】那条明细【不再算数】。只钉表头是不够的:一个只改表头、
    -- 不排除明细的实现照样通过上一条,而它会让不变量当场对不上。
    SELECT count(*), COALESCE(SUM(fce.amount_base), 0) INTO v_n, v_sum
      FROM fixed_asset_cost_entries fce
      JOIN expenses e ON e.id = fce.expense_id
     WHERE fce.asset_id = v_asset AND e.status = 'posted';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 106F2 失败:未冲销的成本明细应当只剩 1 条(建卡那一条),实得 % 条', v_n;
    END IF;
    IF v_sum <> v_cost THEN
        RAISE EXCEPTION 'FIXTURE 106F2 失败:不变量不成立 —— 表头 % 与未冲销明细之和 % 对不上', v_cost, v_sum;
    END IF;
    -- 明细【行本身没有被删掉】:它是审计痕迹,只是不再算数
    SELECT count(*) INTO v_n FROM fixed_asset_cost_entries WHERE asset_id = v_asset;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 106F2 失败:成本明细的【行】应当原样留着(2 行,审计痕迹不删),实得 % —— 不算数与不存在是两回事', v_n;
    END IF;

    -- ══════════ F4 · D2 是铰链:未投用冲得掉,已投用按名拒 ══════════════════
    RAISE NOTICE 'fixture 106 · 进入 F4';
    -- (a) 未投用 —— 冲得掉。【自己建一台】,不借 F2 那台。
    -- 【这一臂是【对照】,不是独立证明 —— 故障注入把这件事挑明了】
    -- 把铰链改成恒拒之后,先红的是 F2(它冲的也是一台未投用的资产),
    -- 所以【没有任何注入能让 (a) 单独红】。它共用 F2 的机制是【故意的】:
    -- 它存在的意义正是排除"(b) 之所以被拒,是因为冲销根本就没用过" ——
    -- 一个阴性对照的价值恰恰来自它与被测项共用机制。写在这里,免得下一个人
    -- 把它当成一条独立的证明,或者反过来把它当成冗余删掉。
    v_res := record_expense(DATE '2026-03-05', '1500', 20000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 106 machine A',
        jsonb_build_object('description', 'fixture 106 machine A', 'useful_life_months', 60), NULL);
    SELECT id INTO v_asset FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    v_res := record_expense(DATE '2026-03-06', '1500', 5000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 106 machine A freight',
        jsonb_build_object('asset_id', v_asset), NULL);
    PERFORM reverse_expense((v_res->>'expense_id')::uuid, 'fixture 106 F4a');
    SELECT cost_base INTO v_cost FROM fixed_assets WHERE id = v_asset;
    IF v_cost <> 20000 THEN
        RAISE EXCEPTION 'FIXTURE 106F4a 失败:【未投用】的资产,它的追加成本应当冲得掉并退回(应 20,000),实得 % —— 少了这一半,下一臂就只证明了"什么都不许冲",而那不是一个铰链', v_cost;
    END IF;

    -- (b) 已投用 —— 按名拒。另建一台,免得 (a) 的处置影响它。
    v_res := record_expense(DATE '2026-03-05', '1500', 20000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 106 machine B',
        jsonb_build_object('description', 'fixture 106 machine B', 'useful_life_months', 60), NULL);
    SELECT id INTO v_asset2 FROM fixed_assets WHERE expense_id = (v_res->>'expense_id')::uuid;
    v_res := record_expense(DATE '2026-03-06', '1500', 5000, v_ccy, NULL, 'unpaid', NULL,
        v_sup, NULL, 'fixture 106 machine B commissioning',
        jsonb_build_object('asset_id', v_asset2), NULL);
    v_exp := (v_res->>'expense_id')::uuid;
    -- 【顺序要紧】record_expense 的追加支对已投用资产是按名拒的,
    -- 所以必须先追加、再投用,才走得到冲销那一步。
    PERFORM set_asset_in_service(v_asset2, DATE '2026-03-10');

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM reverse_expense(v_exp, 'fixture 106 F4b');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('ASSET_IN_SERVICE_COST_LOCKED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 106F4b 失败:资产已投用之后,它的成本不许再被冲回,应按名拒 ASSET_IN_SERVICE_COST_LOCKED,实得 denied=% msg=% —— 折旧已经按那个成本基数算过,而其中若干期可能已经锁进期间,没有任何重述机制',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;
    -- 拒绝之后【什么都没有发生】—— 成本原样,原单仍在册
    SELECT cost_base INTO v_cost FROM fixed_assets WHERE id = v_asset2;
    SELECT status INTO v_status FROM expenses WHERE id = v_exp;
    IF v_cost <> 25000 OR v_status <> 'posted' THEN
        RAISE EXCEPTION 'FIXTURE 106F4b 失败:被拒的冲销不该留下任何痕迹,实得 cost=% status=%', v_cost, v_status;
    END IF;

    -- ══════════ F5 · D3:欠员工的费用单冲得掉,镜像带着同一个人 ══════════════
    RAISE NOTICE 'fixture 106 · 进入 F5';
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, employment_status)
    VALUES ('ZZFIX106-E', 'fixture 106 employee', 'full_time', 'office', CURRENT_DATE - 400, 'active')
    RETURNING id INTO v_emp;

    v_res := record_expense(DATE '2026-04-05', v_exp_acct, 88, v_ccy, NULL, 'unpaid',
        NULL, NULL, NULL, 'fixture 106 staff reimbursement', NULL, v_emp);
    v_exp := (v_res->>'expense_id')::uuid;

    v_res := reverse_expense(v_exp, 'fixture 106 F5');
    v_mirror := (v_res->>'reversal_expense_id')::uuid;
    SELECT employee_id, supplier_id INTO v_emp_on_mirror, v_link
      FROM expenses WHERE id = v_mirror;
    IF v_emp_on_mirror IS DISTINCT FROM v_emp THEN
        RAISE EXCEPTION 'FIXTURE 106F5 失败:镜像单应当带着【同一个员工】,实得 % —— 不抄这一列,expenses_counterparty_shape 会当场抛一条裸的 CHECK 违例(unpaid 必须恰好挂一个往来对象),而那正是本刀退役的那条 known-issue',
            COALESCE(v_emp_on_mirror::text, '(null)');
    END IF;
    IF v_link IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 106F5 失败:欠员工的支出,镜像单不该凭空长出一个供应商,实得 %', v_link;
    END IF;

    RAISE NOTICE 'fixture 106:F1/F2/F4/F5 通过';
END $$;
ROLLBACK;
