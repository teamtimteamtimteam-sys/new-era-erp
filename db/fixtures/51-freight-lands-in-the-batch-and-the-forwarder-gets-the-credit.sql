-- 51 运费资本化:借方进批次成本、贷方【记在货代名下】,而且【走得到毛利】
--
-- 【A 臂:贷方的对手方 —— 两半都要,少一半就漏】
-- 既有的每一条差额路径都贷 2000 且意指【材料供应商】的应付(改价即改欠款)。
-- 运费的贷方是【货代】,另一个对手方。照抄 reprice 的贷方会让分录照样平、
-- 照样不报错,而钱记在错的人头上。所以本臂断言两件事:
--   (1) 应付账龄里那张运费单挂在【货代】名下;
--   (2) 【材料供应商的应付分毫未动】。
-- 只断言 (1),一个"两边都贷"的实现照样通过。
--
-- 【B 臂:拆账 —— 收货即到(ratio=1)与迟到(部分已耗)两个边界】
-- 迟到的运费是【主路径】:收货 → 加工 → 卖出 → 发票才到,是正常顺序。
-- 收货即到只是 ratio = 1 的边界情形,同一条代码路径。
--
-- 【C 臂:口径是承重的 —— 同一船货按重量分与按货值分给出【不同】的数】
-- 而且只改申报的口径就改变结果:写死口径的实现过不了这一臂。
-- 【判别力所在】一批轻而贵、一批重而便宜 —— 重量与货值恰恰在这时分歧最大。
--
-- 【D 臂:value 口径遇未计价批次【点名拒绝】】给它零份额等于把它那部分运费悄悄
-- 摊到别的批次头上,而那是一个没人看得见的错误 —— 正是资本化的代价所在。
--
-- 【E 臂:迟到的运费必须把吃过那批货的加工单标过期 —— 本 fixture 的头号断言】
-- 【一个过账全对、只是忘了标过期的实现,能通过上面每一条断言】:分录对、
-- 对手方对、拆账对、口径对 —— 而 batch_margin 一直停在运费之前的那个数。
-- 所以这一臂单独存在,并且它测的是【视图的第四个过期源】,不是过账。
--
-- 【F 臂:落地成本真的走到了产出批的单位成本】E 臂钉"知道要重算",F 臂钉
-- "重算之后数字真的变了"。两者不互相蕴含:视图标了过期而 allocate 仍只读
-- unit_price,毛利照样不动。
--
-- 【G 臂:GST 是闸门】进口 GST 是可抵扣进项税(1400),资本化它会同时高估存货
-- 【并】毁掉抵扣。
--
-- 日期落在 2027,自带数据(README 第 4/5 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_fwd uuid; v_sup uuid; v_mat uuid; v_cust uuid;
    v_b1 uuid; v_b2 uuid; v_b3 uuid; v_bl uuid;
    v_run uuid; v_ob uuid;
    v_res jsonb; v_msg text; v_denied boolean;
    v_w1 numeric; v_v1 numeric;
    v_n int; v_stale boolean; v_cost_before numeric; v_cost_after numeric;
    v_ccy text; v_b4 uuid; v_bnp uuid;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-51', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.finance.edit','module.finance.view','module.inbound.view',
        'module.inbound.edit','module.processing.view','module.processing.edit',
        'module.output.view','module.output.edit','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX51-MAT', 'fixture 51 material supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX51-FWD', 'fixture 51 forwarder', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_fwd;
    INSERT INTO materials (code, name, category)
    VALUES ('ZZFIX51-M', 'fixture 51 material', 'other') RETURNING id INTO v_mat;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX51-C', 'fixture 51 customer', 'SG') RETURNING id INTO v_cust;

    -- ══════════ A. 贷方记在货代名下,且材料供应商的应付分毫未动 ══════════════
    -- 全新未动的一批:ratio = 1
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX51-IB1', v_mat, v_sup, 100, 100, DATE '2027-07-01', 10) RETURNING id INTO v_b1;

    v_res := record_freight_document(DATE '2027-07-05', v_fwd, 500, v_ccy, 'weight', 'unpaid', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b1)), 'fixture 51', NULL);

    SELECT count(*) INTO v_n FROM ap_open_items
     WHERE doc_kind = 'freight' AND doc_code = (v_res->>'code')
       AND supplier_id = v_fwd AND open_base = 500;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 51A 失败:未付运费应作为一张【货代】名下的应付单据出现在账龄里(500),实得 % 行 —— 少了这一支,那笔钱在总账里躺着、在账龄表上不存在',
            v_n;
    END IF;
    -- 【第二半:材料供应商没有被牵连】—— 只断言上一半,"两边都贷"的实现照样通过
    SELECT COALESCE(sum(open_base), 0) INTO v_v1 FROM ap_open_items
     WHERE supplier_id = v_sup;
    IF v_v1 <> 1000 THEN     -- 100 × 10,那批货本身的应付,一分不多不少
        RAISE EXCEPTION 'FIXTURE 51A 失败:材料供应商的应付应仍是 1,000(100×10),实得 % —— 运费的贷方一旦记到材料供应商名下,分录照样是平的、照样不报错,而钱记在了错的人头上',
            v_v1;
    END IF;
    -- 分录本身:借 1200(全在库)、贷 2000
    SELECT count(*) INTO v_n
      FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
      JOIN journal_entries je ON je.id = jl.entry_id
     WHERE je.source_type = 'freight' AND je.source_id = (v_res->>'freight_document_id')::uuid
       AND a.code = '1200' AND jl.debit = 500;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 51A 失败:整批在库时运费应全额借 1200,实得 % 行', v_n;
    END IF;
    IF (v_res->>'in_stock_base')::numeric <> 500 OR (v_res->>'consumed_base')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 51A 失败:ratio=1 时应全进在库(500/0),实得 %/%',
            v_res->>'in_stock_base', v_res->>'consumed_base';
    END IF;

    -- ══════════ B. 迟到的运费:部分已耗 → 拆 1200 / 5000 ═════════════════════
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX51-IB2', v_mat, v_sup, 100, 40, DATE '2027-07-01', 10) RETURNING id INTO v_b2;
    v_res := record_freight_document(DATE '2027-07-20', v_fwd, 1000, v_ccy, 'weight', 'paid', '1000',
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b2)), 'fixture 51 late', NULL);
    -- 在库 40% → 400 进 1200,600 进 5000
    IF (v_res->>'in_stock_base')::numeric <> 400 OR (v_res->>'consumed_base')::numeric <> 600 THEN
        RAISE EXCEPTION 'FIXTURE 51B 失败:在库 40%% 时应拆成 400/600,实得 %/% —— 迟到的运费是主路径,拆账比例取【过账那一刻】',
            v_res->>'in_stock_base', v_res->>'consumed_base';
    END IF;
    SELECT in_stock_ratio INTO v_v1 FROM freight_allocations
     WHERE freight_document_id = (v_res->>'freight_document_id')::uuid;
    IF v_v1 <> 0.4 THEN
        RAISE EXCEPTION 'FIXTURE 51B 失败:拆账比例应记在行上(0.4),实得 % —— 事后重算得到的是另一个答案,remaining_qty 还会继续变', v_v1;
    END IF;

    -- ══════════ C. 口径承重:同一船货,按重量与按货值给出不同的数 ═════════════
    -- 【判别力】轻而贵 vs 重而便宜
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX51-LIGHT', v_mat, v_sup, 10, 10, DATE '2027-08-01', 100) RETURNING id INTO v_b3;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX51-HEAVY', v_mat, v_sup, 90, 90, DATE '2027-08-01', 1) RETURNING id INTO v_bl;

    v_res := record_freight_document(DATE '2027-08-05', v_fwd, 1000, v_ccy, 'weight', 'paid', '1000',
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b3),
                          jsonb_build_object('inbound_batch_id', v_bl)), 'by weight', NULL);
    SELECT amount_base INTO v_w1 FROM freight_allocations
     WHERE freight_document_id = (v_res->>'freight_document_id')::uuid AND inbound_batch_id = v_b3;

    v_res := record_freight_document(DATE '2027-08-06', v_fwd, 1000, v_ccy, 'value', 'paid', '1000',
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b3),
                          jsonb_build_object('inbound_batch_id', v_bl)), 'by value', NULL);
    SELECT amount_base INTO v_v1 FROM freight_allocations
     WHERE freight_document_id = (v_res->>'freight_document_id')::uuid AND inbound_batch_id = v_b3;

    -- 重量:10/100 → 100;货值:1000/1090 → 917.43
    IF v_w1 <> 100 OR round(v_v1, 2) <> 917.43 THEN
        RAISE EXCEPTION 'FIXTURE 51C 失败:轻而贵那一批按重量应分到 100、按货值应分到 917.43,实得 % 与 %',
            v_w1, round(v_v1, 2);
    END IF;
    IF v_w1 = v_v1 THEN
        RAISE EXCEPTION 'FIXTURE 51C 失败:两种口径给出了【同一个数】—— 那么"逐单申报口径"这件事在系统里不存在(口径写死的实现正是这样)';
    END IF;
    -- basis_qty 记下这一份是从什么数算出来的 —— 分摊要能被重新导出
    SELECT basis_qty INTO v_v1 FROM freight_allocations
     WHERE freight_document_id = (v_res->>'freight_document_id')::uuid AND inbound_batch_id = v_b3;
    IF v_v1 <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 51C 失败:value 口径的 basis_qty 应是该批货值 1,000(10×100),实得 % —— 一个无法被重新导出的分摊,是一个只能被相信的数字',
            v_v1;
    END IF;

    -- ══════════ D. value 口径遇未计价批次:点名拒绝 ══════════════════════════
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, pricing_status)
    VALUES ('ZZFIX51-NOPRICE', v_mat, v_sup, 50, 50, DATE '2027-08-01', 'unpriced')
    RETURNING id INTO v_bnp;
    v_denied := false;
    BEGIN
        PERFORM record_freight_document(DATE '2027-08-07', v_fwd, 1000, v_ccy, 'value', 'paid', '1000',
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b3),
                              jsonb_build_object('inbound_batch_id', v_bnp)), NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'FREIGHT_BATCH_UNPRICED|ZZFIX51-NOPRICE' THEN
        RAISE EXCEPTION 'FIXTURE 51D 失败:value 口径遇未计价批次应点名拒绝,实得 denied=% msg=% —— 给它零份额等于把它那部分运费悄悄摊到别的批次头上,而那正是资本化之后【看不见】的那种错',
            v_denied, COALESCE(v_msg, '(算出来了)');
    END IF;

    -- ══════════ E. 迟到的运费必须让吃过那批货的加工单【过期】═════════════════
    -- 【本 fixture 的头号断言】一个过账全对、只是忘了标过期的实现,能通过上面每一条。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX51-IB4', v_mat, v_sup, 100, 100, DATE '2027-09-01', 10) RETURNING id INTO v_b4;
    v_run := commit_processing_run(DATE '2027-09-02', 'fixture 51 run', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b4, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 80)), 'weight');
    SELECT po.output_batch_id INTO v_ob FROM processing_outputs po WHERE po.run_id = v_run;
    PERFORM allocate_processing_costs(v_run);

    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run;
    IF v_stale THEN
        RAISE EXCEPTION 'FIXTURE 51E 前置失败:刚分摊完的单不该是过期的 —— 前置就红,后面那一半测不到东西';
    END IF;
    SELECT unit_cost_base INTO v_cost_before FROM processing_outputs WHERE run_id = v_run;

    -- 【把"这单是早先分摊的"这个前提显式设出来】now() 是【事务时间】,同一个事务里
    -- 它是常量 —— 而 fixture 整个跑在一个事务里,于是 allocated_at 与运费行的
    -- created_at 【完全相等】,`last_cost_change > allocated_at` 恒假。
    -- 这不是缺陷,是 FIN-36c 已经记过的那个陷阱(allocate 的注释里写着:
    -- "任何看 allocated_at 变没变的判据都会失效,因为 fixture 就在一个事务里跑")。
    -- 现实里运费是几天后到的,所以这里把分摊时点拨回去 —— 设定前提,不是绕过断言:
    -- 【视图里少了运费这个来源,last_cost_change 会是 NULL,这一臂照样红】,
    -- 因为这张单没有成本条目、也没有重定价。
    UPDATE processing_runs SET allocated_at = now() - interval '3 days' WHERE id = v_run;

    -- 运费迟到:这批货已经被全部消耗掉了(remaining_qty = 0 → ratio = 0 → 全进 5000)
    PERFORM record_freight_document(DATE '2027-09-10', v_fwd, 800, v_ccy, 'weight', 'paid', '1000',
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b4)), 'late freight', NULL);

    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run;
    IF NOT v_stale THEN
        RAISE EXCEPTION 'FIXTURE 51E 失败:迟到的运费改变了这张单的材料成本,它必须被标为【过期】,实得 is_stale=false —— 过账可以完全正确而这一步漏掉,于是 batch_margin 一直停在运费之前的那个数,没有任何东西说过一句话。这是本刀的头号缺陷,不是可选项';
    END IF;

    -- ══════════ F. 重分摊之后,落地成本真的进了产出批的单位成本 ═══════════════
    -- E 臂钉"知道要重算",F 臂钉"重算之后数字真的变了" —— 视图标了过期而 allocate
    -- 仍只读 unit_price 的话,毛利照样不动。
    PERFORM allocate_processing_costs(v_run);
    SELECT unit_cost_base INTO v_cost_after FROM processing_outputs WHERE run_id = v_run;
    IF v_cost_after <= v_cost_before THEN
        RAISE EXCEPTION 'FIXTURE 51F 失败:重分摊之后单位成本应当【变高】(运费进了落地成本),实得 % → % —— 相等说明 allocate 仍只读 unit_price,运费停在 1200/5000 走不到毛利',
            v_cost_before, v_cost_after;
    END IF;
    -- 手算:材料 100×10 = 1,000 + 运费 800 = 1,800,产出 80 → 22.50/单位
    IF round(v_cost_after, 4) <> 22.5 THEN
        RAISE EXCEPTION 'FIXTURE 51F 失败:落地成本 (100×10 + 800) / 80 应为 22.50,实得 % —— 这个数是手算的,写在断言旁边正是为了它日后能被重新核对',
            round(v_cost_after, 4);
    END IF;

    -- ══════════ G. GST 是闸门,不是备注 ═════════════════════════════════════
    v_denied := false;
    BEGIN
        PERFORM record_freight_document(DATE '2027-09-12', v_fwd, 500, v_ccy, 'weight', 'paid', '1000',
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b1)), NULL, 45);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'FREIGHT_GST_NOT_CAPITALISABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 51G 失败:GST 部分应点名拒收,实得 denied=% msg=% —— 进口 GST 是可抵扣进项税,资本化它会同时高估存货【并】毁掉抵扣',
            v_denied, COALESCE(v_msg, '(收下了)');
    END IF;
END $$;
ROLLBACK;
