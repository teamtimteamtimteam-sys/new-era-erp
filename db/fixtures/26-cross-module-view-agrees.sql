-- 26 跨模块视图:限权读者拿到的是【真答案】或【明说的 NULL】,绝不是编出来的 0
--
-- 为什么值得常设(OPS-14):security_invoker 视图跨模块 JOIN 时不是在限制,而是在
-- 说谎 —— 读不到的行安静消失,内连接掉整行、外连接掉成 NULL、聚合掉成 0,而派生列
-- 正是从这些行算出来的。没有报错,只有一个【因人而异】的错答案。
--
-- gate 的 xmodule 判据抓的是【形状】(invoker × 跨模块基表)。本 fixture 抓的是
-- 【行为】:同一行,换一个读者,答案必须一样。两者缺一不可 —— 形状检查看不见
-- 属主权限视图里漏写的那一道谓词,行为断言看不见还没被谁读到的下一个视图。
--
-- 四支,每支对应一个上线时真错过的方向:
--   A safe_to_reallocate —— 假阴性:真值 true,operations 读 NULL,页面挂红条
--   B system_start_not_set —— 假阳性:日期填了,hr 读到一条【清不掉】的告警
--   C batch_assay_status —— 整行消失:admin 10 行,warehouse 0 行
--   D purchase_order_status.prepaid_base —— 金额读成 0(而不是"看不见")
--
-- 【为什么 D 断言 NULL 而不是断言"看得见"】预付是【金额】,不该给没有财务模块的人;
-- 但 0.00 与「受限」在屏幕上是两回事,前者是谎。这一支钉住的正是这个区别。
--
-- ⚠️【每一次读都必须 SET LOCAL ROLE authenticated —— 否则 A/C 两支是空的】
-- fixture 默认以 postgres 跑,而 postgres 【绕过 RLS】。本条断言的病【就是 RLS
-- 让行消失】,所以不换角色的话,invoker 与属主权限读起来一模一样,两支永远绿。
-- 第一版正是这么写的:把 processing_run_allocation_status 改回 invoker 注入故障,
-- gate 的 xmodule 判据红了,而这份 fixture 【依旧绿】—— 与 FIN-30 第三臂同一种
-- 空转,记在这里免得下一个人再写一遍。
-- has_permission() 不受影响:它按 request.jwt.claims 里的 sub 解析,与数据库角色无关,
-- 所以 B/D 两支本来就有效 —— 但 A/C 靠的是 RLS,必须换角色。
BEGIN;
DO $$
DECLARE
    v_all uuid := gen_random_uuid();     -- 全权限读者(真值的参照)
    v_proc uuid := gen_random_uuid();    -- 只有加工模块
    v_hr uuid := gen_random_uuid();      -- 只有 HR 模块
    v_inb uuid := gen_random_uuid();     -- 只有进料模块(没有供应商/物料模块)
    v_pur uuid := gen_random_uuid();     -- 只有采购模块(没有财务)
    r_all uuid; r_proc uuid; r_hr uuid; r_inb uuid; r_pur uuid;
    v_sup uuid; v_mat uuid; v_batch uuid; v_po uuid; v_pay uuid; v_run uuid;
    v_je jsonb; v_entry uuid;
    v_truth_safe boolean; v_seen_safe boolean;
    v_truth_rows bigint; v_seen_rows bigint;
    v_truth_prepaid numeric; v_seen_prepaid numeric;
    v_alerts bigint;
BEGIN
    -- ── 角色:自建,不借引导角色(README)────────────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-26-all','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;

    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-26-proc','f','f',true) RETURNING id INTO r_proc;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_proc,'module.processing.view');

    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-26-hr','f','f',true) RETURNING id INTO r_hr;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_hr,'module.hr.view');

    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-26-inb','f','f',true) RETURNING id INTO r_inb;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_inb,'module.inbound.view'), (r_inb,'data.view_prices');

    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-26-pur','f','f',true) RETURNING id INTO r_pur;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_pur,'module.purchasing.view'), (r_pur,'data.view_prices');

    INSERT INTO user_roles (user_id, role_id) VALUES (v_all,r_all),(v_proc,r_proc),(v_hr,r_hr),(v_inb,r_inb),(v_pur,r_pur);

    -- ── 前提显式设定(README 第 5 条)────────────────────────────────────
    UPDATE finance_settings SET locked_before = NULL, system_start_date = DATE '2020-01-01';

    -- ── 数据:每个用例自带,重建库里无处可借 ─────────────────────────────
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_all), true);

    INSERT INTO suppliers (legal_name, country, status, counterparty_type) VALUES ('ZZ-FIX26 Supplier','SG','active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (name, kind_code, may_be_processed, form_code, source_code, unit, status) VALUES ('ZZ-FIX26 Material', 'battery_material', true, 'black_mass', 'end_of_life','kg','active') RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, unit_price, pricing_status, status)
        VALUES (v_mat, v_sup, 100, 'kg', 100, DATE '2026-03-02', 5, 'final', 'active') RETURNING id INTO v_batch;

    -- 一张已过账的分录,给加工单当资本化分录用(真值 safe_to_reallocate = true)
    v_je := post_journal_entry(DATE '2026-03-02', 'ZZ-FIX26 capitalization', 'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','1220','side','debit','currency',base_currency_code(),'amount_ccy',100),
            jsonb_build_object('account_code','1200','side','credit','currency',base_currency_code(),'amount_ccy',100)));
    v_entry := (v_je->>'entry_id')::uuid;

    INSERT INTO processing_runs (process_date, total_input, total_output, loss_qty, status, allocation_basis,
                                 allocated_at, capitalization_entry_id, capitalized_cost_base, operation_type_code)
        VALUES (DATE '2026-03-02', 100, 90, 10, 'committed', 'weight', now(), v_entry, 100, 'manual_disassembly')
        RETURNING id INTO v_run;

    -- 采购单 + 一笔已过账的预付,给 D 支一个【非零】的真值
    -- purchase_orders 的编号【没有触发器】—— create_purchase_order 自己调
    -- next_purchase_order_code()(无缝编号,见表头注释)。直插就得自己取号。
    -- FIN-35:fx_rate 不再有默认值 —— 直插就得自己给。本位币恒 1(fx_rate_asof
    -- 对本位币直接返回 1,不查牌价表),所以这里显式写 1 是【记录事实】,不是兜底。
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status)
        VALUES (next_purchase_order_code(DATE '2026-03-02'), v_sup, DATE '2026-03-02', base_currency_code(), 1, 'confirmed')
        RETURNING id INTO v_po;
    -- payments 同样无取号触发器(record_payment 自己调 fin_next_payment_code,
    -- 出款前缀 'PMT')。这里不走 record_payment:它会连带过账分录、要牌价、
    -- 碰期间锁 —— 本 fixture 要断言的是【视图怎么读】,不是付款怎么记。
    INSERT INTO payments (code, direction, counterparty_type, payment_date, currency, fx_rate, amount_ccy, amount_base, status, supplier_id, bank_account_code)
        VALUES (fin_next_payment_code('PMT', DATE '2026-03-02'), 'out', 'supplier', DATE '2026-03-02',
                base_currency_code(), 1, 500, 500, 'posted', v_sup, '1000') RETURNING id INTO v_pay;
    INSERT INTO payment_allocations (payment_id, purchase_order_id, allocated_ccy, allocated_base, allocated_pay)
        VALUES (v_pay, v_po, 500, 500, 500);

    -- ═══ A. safe_to_reallocate —— 加工的人必须拿到【真答案】 ═══════════════
    -- 借的是 journal_entries.status(finance)与 price_history(inbound):两个
    -- 【派生事实】的原料,不是金额。真值 true;OPS-14 之前 processing-only 读 NULL,
    -- 而 /processing/[id] 在这个布尔上分支、NULL 是 falsy —— 红条挂在一张好单上。
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT safe_to_reallocate INTO v_truth_safe FROM processing_run_allocation_status WHERE run_id = v_run;
    RESET ROLE;
    IF v_truth_safe IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 26A 前提不成立:全权限读者读到的 safe_to_reallocate 应为 true,实得 % —— 用例本身没搭对', v_truth_safe;
    END IF;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_proc), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT safe_to_reallocate INTO v_seen_safe FROM processing_run_allocation_status WHERE run_id = v_run;
    RESET ROLE;
    IF v_seen_safe IS DISTINCT FROM v_truth_safe THEN
        RAISE EXCEPTION 'FIXTURE 26A 失败:只有 module.processing.view 的读者读到 safe_to_reallocate = %,全权限读者读到 % —— 同一行不该因读者而异',
            COALESCE(v_seen_safe::text,'NULL'), v_truth_safe;
    END IF;

    -- ═══ B. system_start_not_set —— 行消失制造的是【假阳性】 ═══════════════
    -- 该支写作 NOT EXISTS(finance_settings ...),而 finance_settings 挂 finance 模块。
    -- 行一消失,条件恒真:日期【明明填了】(上面设成 2020-01-01),hr 角色却看见
    -- 一条永远清不掉的告警 —— 因为驱动它的那张表他读不到。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_hr), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_alerts FROM hr_alerts WHERE alert_type = 'system_start_not_set';
    RESET ROLE;
    IF v_alerts <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 26B 失败:system_start_date 已设为 2020-01-01,只有 module.hr.view 的读者仍看见 % 条 system_start_not_set —— 一条他无论如何也清不掉的假告警', v_alerts;
    END IF;

    -- ═══ C. batch_assay_status —— 整行不该因为看不见供应商而消失 ════════════
    -- 借的只有 sup.legal_name 与 m.name 两个【标签】。INNER JOIN 时,没有
    -- 供应商/物料模块的读者拿到 0 行 —— 而他看得见这个进料批本身。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_truth_rows FROM batch_assay_status WHERE inbound_batch_id = v_batch;
    RESET ROLE;
    IF v_truth_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 26C 前提不成立:全权限读者应看到 1 行,实得 %', v_truth_rows;
    END IF;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_inb), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_seen_rows FROM batch_assay_status WHERE inbound_batch_id = v_batch;
    RESET ROLE;
    IF v_seen_rows <> v_truth_rows THEN
        RAISE EXCEPTION 'FIXTURE 26C 失败:只有 module.inbound.view 的读者读到 % 行,全权限读者读到 % 行 —— 看不见供应商的名字不该让整个批次消失',
            v_seen_rows, v_truth_rows;
    END IF;
    -- 标签跟着单据走(Tim 2026-08-08 的裁定):名字要真的在
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_seen_rows FROM batch_assay_status WHERE inbound_batch_id = v_batch
       AND supplier_name = 'ZZ-FIX26 Supplier' AND material_name = 'ZZ-FIX26 Material';
    RESET ROLE;
    IF v_seen_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 26C 失败:主数据【标签】应当跟着单据走 —— 供应商名或物料名为空';
    END IF;

    -- ═══ D. prepaid_base —— 金额是【NULL(受限)】,不是 0(谎)═══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT prepaid_base INTO v_truth_prepaid FROM purchase_order_status WHERE po_id = v_po;
    RESET ROLE;
    IF v_truth_prepaid IS DISTINCT FROM 500 THEN
        RAISE EXCEPTION 'FIXTURE 26D 前提不成立:全权限读者应读到预付 500,实得 % —— 用例本身没搭对', COALESCE(v_truth_prepaid::text,'NULL');
    END IF;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_pur), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT prepaid_base INTO v_seen_prepaid FROM purchase_order_status WHERE po_id = v_po;
    RESET ROLE;
    IF v_seen_prepaid IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 26D 失败:没有 module.finance.view 的读者读到预付 % —— 应当是 NULL(界面画「受限」)。0.00 与「受限」是两回事,前者是谎',
            v_seen_prepaid;
    END IF;
    -- 而这一行【本身】必须还在:存在判据是采购的,不是财务的
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_seen_rows FROM purchase_order_status WHERE po_id = v_po;
    RESET ROLE;
    IF v_seen_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 26D 失败:采购单在采购模块读者眼里应当还在 —— 遮的是三列金额,不是整行';
    END IF;
END $$;
ROLLBACK;
