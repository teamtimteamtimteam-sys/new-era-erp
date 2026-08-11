-- 30 operations_now:条件成立时那一支【有】这一行,解除后【没有】;
--    只持一个模块的读者,恰好只看见那个模块的支
--
-- OPS-19:十五支。支的规格(含被排除的候选)在 docs/dashboard-arm-inventory.md。
--
-- 【为什么值得常设(OPS-18)】首页看板的每个数字都出自这张视图的一支。一支的条件
-- 写错,屏幕上是一个像模像样的数字,不是错误 —— 少算的样子与"处理完了"一模一样,
-- 多算的样子与"还有活"一模一样,两个方向都无声。所以每支都要两头断言:
-- 条件成立【在】,条件解除【不在】。只断言一头,一个恒真或恒假的条件照样通过。
--
-- 【可见性断言必须切数据库角色】(README 第 6 条)。本视图是属主权限,行的裁决在
-- WHERE has_permission(permission) —— has_permission 读 request.jwt.claims,按调用者
-- 解析。fixture 以 postgres 跑,不切角色也能拿到"像是对的"结果;切了角色,断言才
-- 走过与真实读者相同的门(GRANT SELECT TO authenticated 也因此被顺带验证)。
--
-- 【日期自设,不继承】(README 第 4 条)。全部业务行落在 2027,与引导数据、
-- locked_before 之类随月末移动的状态无关;locked_before 在开头显式清空 ——
-- 成本条目的自动应计触发器会过账,不能让它撞上某个未来月份的锁。
BEGIN;
DO $$
DECLARE
    v_all uuid := gen_random_uuid();   -- 持全部六个模块 view 码
    v_inb uuid := gen_random_uuid();   -- 只持 module.inbound.view
    r_all uuid; r_inb uuid;
    v_sup uuid; v_mat uuid; v_ib uuid; v_ar uuid;
    v_run uuid; v_po uuid; v_st uuid; v_emp1 uuid; v_emp2 uuid;
    v_lr uuid; v_mc uuid; v_pr uuid; v_bs uuid; v_bl uuid;
    v_je uuid;
    v_ib2 uuid; v_ib3 uuid; v_ib4 uuid; v_ar3 uuid;
    v_ob uuid; v_ob2 uuid; v_cust uuid; v_sr uuid; v_inv uuid;
    v_ccy text;
    v_types text[];
    v_n int;
    v_expected text[] := ARRAY['allocation_stale','ap_over_90','ar_over_90',
        'assay_unapplied','awaiting_assay','bank_unmatched','batch_unpriced',
        'claim_pending','fx_rate_gap','invoice_overdue','leave_pending',
        'output_unsold_aging','po_awaiting_receipt','review_submitted','stocktake_open'];
    -- 只持 module.inbound.view 的读者应看见的三支(同源 batch_assay_status,互斥)
    v_inbound_only text[] := ARRAY['assay_unapplied','awaiting_assay','batch_unpriced'];
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    -- 成本条目会触发自动应计过账 —— 锁不能挡住 fixture 自己的日期(回滚,无副作用)
    UPDATE finance_settings SET locked_before = NULL;

    -- ── 角色 ────────────────────────────────────────────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-30-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    -- 【为什么带 data.view_prices】invoice_overdue / ar_over_90 / ap_over_90 三支的
    -- 行【存在性】挂在被它遮蔽的金额列上(见 docs/dashboard-arm-inventory.md 的隐患一节):
    -- 没有它,这三支会静默少报而不是显示「受限」。live 上任何持 finance 的角色都同时
    -- 持它(常设决定 1),所以这里照着现实配。
    -- PUR-2:C 臂改走 close_purchase_order 解除 po_awaiting_receipt(状态不再能经
    -- 直连 UPDATE 改动),而关单要 module.purchasing.edit —— 加这个码不影响任何一支
    -- (支挂的都是 .view),arm B 用的也是另一个角色。
    SELECT r_all, unnest(ARRAY['module.inbound.view','module.processing.view',
        'module.purchasing.view','module.purchasing.edit','module.stocktakes.view','module.hr.view',
        'module.output.view','module.finance.view','data.view_prices']);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-30-inb', 'f', 'f', true) RETURNING id INTO r_inb;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_inb, 'module.inbound.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_all, r_all), (v_inb, r_inb);

    -- ── 九支的数据,每支一个等待中的条件 ─────────────────────────────────────
    INSERT INTO suppliers (code, legal_name, country)
    VALUES ('ZZFIX30-S', 'fixture 30 supplier', 'SG') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, category)
    VALUES ('ZZFIX30-M', 'fixture 30 material', 'other') RETURNING id INTO v_mat;

    -- 1 assay_unapplied:化验已录、applied_at 为空
    -- arrival_date 必填不是本支的条件,是 FIN-32:进料触发器把它抄成收货台账行的
    -- business_date,而新台账行的 business_date 有 CHECK(空着整个 INSERT 被拒)。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX30-IB', v_mat, v_sup, 10, 10, '2027-01-08') RETURNING id INTO v_ib;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date)
    VALUES ('ZZFIX30-AR', v_ib, '2027-01-10') RETURNING id INTO v_ar;

    -- 2 allocation_stale:分摊时点(2027-01-01)早于成本变动时点(2027-02-01)
    -- FIN-36:allocation_basis 不再有 schema 默认值 —— 直插就得自己选。
    -- 'metal_value' 是这些 fixture 在 FIN-36 之前拿到的那个值,语义不变。
    INSERT INTO processing_runs (code, status, allocated_at, allocation_basis)
    VALUES ('ZZFIX30-RUN', 'committed', '2027-01-01', 'metal_value') RETURNING id INTO v_run;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, created_at, updated_at)
    VALUES (v_run, 'electricity', 100, '2027-02-01', '2027-02-01');

    -- 3 po_awaiting_receipt:已确认
    -- FIN-35:fx_rate 不再有默认值 —— 直插就得自己给。本位币恒 1(fx_rate_asof
    -- 对本位币直接返回 1,不查牌价表),所以这里显式写 1 是【记录事实】,不是兜底。
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status)
    VALUES ('ZZFIX30-PO', v_sup, '2027-01-15', v_ccy, 1, 'confirmed') RETURNING id INTO v_po;

    -- 4 stocktake_open:默认即 open
    INSERT INTO stocktakes (code) VALUES ('ZZFIX30-ST') RETURNING id INTO v_st;

    -- 5/6/7 HR 三支
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZFIX30-E1', 'fixture 30 employee', 'full_time', 'office', '2027-01-01')
    RETURNING id INTO v_emp1;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZFIX30-E2', 'fixture 30 reviewer', 'full_time', 'office', '2027-01-01')
    RETURNING id INTO v_emp2;
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days)
    VALUES ('ZZFIX30-LR', v_emp1, 'sick', '2027-06-01', '2027-06-01', 1) RETURNING id INTO v_lr;
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd)
    VALUES ('ZZFIX30-MC', v_emp1, '2027-04-10', 2027, 50) RETURNING id INTO v_mc;
    -- 试用期评估(annual 要挂 cycle_id —— cycle_shape);submitted 要求评级 + 评语 +
    -- 试用期结论(submitted_shape / probation_outcome_shape 的闸门都在这一档)
    INSERT INTO performance_reviews (employee_id, reviewer_employee_id, review_type,
        period_start, period_end, status, submitted_at, rating_code, summary_text, probation_outcome)
    VALUES (v_emp1, v_emp2, 'probation', '2027-01-01', '2027-06-30', 'submitted', '2027-07-05',
            'MEETS', 'fixture 30', 'confirm')
    RETURNING id INTO v_pr;

    -- 8 fx_rate_gap:2027-03-03(周三,工作日)有 USD 过账、无任何一侧牌价。
    -- 【未来日期是有意的】本支限 rate_date >= CURRENT_DATE - 45,未来日期恒在界内,
    -- fixture 便不依赖"跑在哪一天"。
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('ZZFIX30-JE', '2027-03-03', 'fixture 30 fx gap', 'manual') RETURNING id INTO v_je;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    SELECT v_je, a.id, x.d, x.c, 'USD', 100, 1.3
    FROM (VALUES ('1010', 130.0, 0.0), ('4000', 0.0, 130.0)) x(code, d, c)
    JOIN accounts a ON a.code = x.code;

    -- 9 bank_unmatched:导入的报表行,未匹配
    INSERT INTO bank_statements (code, bank_account_code, currency, period_start, period_end,
        opening_balance, closing_balance)
    VALUES ('ZZFIX30-BS', '1000', v_ccy, '2027-05-01', '2027-05-31', 0, 10) RETURNING id INTO v_bs;
    INSERT INTO bank_statement_lines (statement_id, line_no, line_date, amount)
    VALUES (v_bs, 1, '2027-05-05', 10) RETURNING id INTO v_bl;

    -- ── OPS-19 追加的六支 ────────────────────────────────────────────────────
    -- 【这几支的日期必须相对 CURRENT_DATE】账龄档与 60 天阈值都是拿 CURRENT_DATE 减出来的,
    -- 2027 那些【未来】日期会落进 b0_30 而不是 b90_plus。相对日期同时满足 README 第 4 条:
    -- 不继承任何时点状态,自己声明"多久以前"。

    -- 10 awaiting_assay:一份化验都没有(与 assay_unapplied 互斥)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX30-IB2', v_mat, v_sup, 10, 10, '2027-01-09') RETURNING id INTO v_ib2;

    -- 11 batch_unpriced:未计价,且化验【已执行】—— 于是只落进 batch_unpriced 这一支
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, pricing_status)
    VALUES ('ZZFIX30-IB3', v_mat, v_sup, 10, 10, '2027-01-11', 'unpriced') RETURNING id INTO v_ib3;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('ZZFIX30-AR3', v_ib3, '2027-01-12', now()) RETURNING id INTO v_ar3;

    -- 12 ap_over_90:有单价的进料单,到货 200 天前(化验已执行,不污染进料三支)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX30-IB4', v_mat, v_sup, 10, 10, CURRENT_DATE - 200, 100) RETURNING id INTO v_ib4;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('ZZFIX30-AR4', v_ib4, CURRENT_DATE - 200, now());

    -- 13 ar_over_90 + 14 invoice_overdue:一笔 200 天前的销售,未收款;
    -- 发票引用同一条销售记录 —— 两支同源不同粒度(单据 vs 销售事实),都该亮。
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX30-C', 'fixture 30 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX30-OB', v_mat, 100, 100, CURRENT_DATE - 10) RETURNING id INTO v_ob;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
        currency, fx_rate, amount_base, sale_date)
    VALUES (v_ob, v_cust, 10, 50, v_ccy, 1, 500, CURRENT_DATE - 200) RETURNING id INTO v_sr;
    INSERT INTO invoices (code, customer_id, issue_date, due_date, payment_terms_days,
        currency, subtotal_base, total_base, bill_to_snapshot)
    VALUES ('ZZFIX30-INV', v_cust, CURRENT_DATE - 200, CURRENT_DATE - 170, 30,
        v_ccy, 500, 500, '{}'::jsonb) RETURNING id INTO v_inv;
    INSERT INTO invoice_lines (invoice_id, sales_record_id, line_no, description,
        quantity, unit, unit_price, amount_base)
    VALUES (v_inv, v_sr, 1, 'fixture 30 line', 10, 'kg', 50, 500);

    -- 15 output_unsold_aging:成品压了 90 天还没卖完(阈值 60 —— 提议值,见规格文件)
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX30-OB2', v_mat, 40, 40, CURRENT_DATE - 90) RETURNING id INTO v_ob2;

    -- ══════════ A. 条件成立:十五支【每支都在】══════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(array_agg(DISTINCT item_type ORDER BY item_type), '{}') INTO v_types
      FROM operations_now;
    RESET ROLE;

    IF v_types <> v_expected THEN
        RAISE EXCEPTION 'FIXTURE 30A 失败:十五支条件全部成立,应恰好看见 %,实得 % —— 少一支是条件恒假(那块牌子永远 0),多一支是支列表变了而 fixture 没跟上(规格见 docs/dashboard-arm-inventory.md)',
            v_expected::text, v_types::text;
    END IF;

    -- 每支恰好一件(本 fixture 的库里只有自己的数据 —— fixtures 各自回滚,互不遗留)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now;
    RESET ROLE;
    IF v_n <> 15 THEN
        RAISE EXCEPTION 'FIXTURE 30A 失败:应恰好 15 行(每支 1 件),实得 % 行 —— 两件说明某支把同一件事数了两遍(进料三支互斥、AR 与发票同源不同粒度)', v_n;
    END IF;

    -- ══════════ B. 只持 inbound 的读者:恰好只看见 inbound 的三支 ════════════
    -- 其余十二支此刻条件【全部成立】—— 缺席只能来自权限,不能来自碰巧没数据。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_inb), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(array_agg(DISTINCT item_type ORDER BY item_type), '{}') INTO v_types
      FROM operations_now;
    RESET ROLE;

    IF v_types <> v_inbound_only THEN
        RAISE EXCEPTION 'FIXTURE 30B 失败:只持 module.inbound.view 应恰好看见 %,实得 % —— 多的支是权限裁决漏了(0 会冒充成一个真数字),少的支是把自己模块的也裁掉了',
            v_inbound_only::text, v_types::text;
    END IF;

    -- ══════════ C. 条件逐支解除:九支【每支都不在】═══════════════════════════
    UPDATE assay_results SET applied_at = now() WHERE id = v_ar;
    UPDATE processing_runs SET allocated_at = '2027-03-01' WHERE id = v_run;  -- 晚于成本变动
    -- 【claims 要先切回全权限那个人】B 臂把它换成了只持 inbound 的读者,
    -- 而 close_purchase_order 要 module.purchasing.edit —— 不切回来就是
    -- PERMISSION_DENIED,而那与本臂要测的东西毫无关系。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    -- PUR-2:状态不再能经一条直连的 UPDATE 改动(guard_po_amendable)。
    -- 【改成走真正的那条路】—— 现实里这一支就是被"关单"清掉的,
    -- 用 close_purchase_order 反而比原来更贴近它要模拟的事。
    PERFORM close_purchase_order(v_po, 'fixture 30:解除 po_awaiting_receipt');
    UPDATE stocktakes SET status = 'cancelled' WHERE id = v_st;
    UPDATE leave_requests SET status = 'approved' WHERE id = v_lr;
    UPDATE medical_claims SET status = 'approved' WHERE id = v_mc;
    UPDATE performance_reviews SET status = 'approved' WHERE id = v_pr;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    SELECT 'USD', '2027-03-03', t, 1.3 FROM unnest(ARRAY['tt_buy','tt_sell','mid']) t;
    UPDATE bank_statement_lines SET match_status = 'ignored' WHERE id = v_bl;
    -- OPS-19 六支的解除。销售记录【不可改也不可删】(SALE_IMMUTABLE),所以 AR 与
    -- 发票只能靠【收款核销】清掉 —— 那本来就是它们在现实里消失的唯一方式,一笔全额
    -- 收款同时结清 ar_over_90 与 invoice_overdue(发票的已结额就是从销售记录推的)。
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('ZZFIX30-AR2', v_ib2, '2027-01-20', now());              -- awaiting_assay 解除
    UPDATE inbound_batches SET pricing_status = 'final' WHERE id = v_ib3;   -- batch_unpriced
    UPDATE output_batches SET output_date = CURRENT_DATE - 1 WHERE id = v_ob2;  -- 不再滞销
    -- payments_counterparty_shape:in 必须带 customer_id,out 必须带 supplier_id
    INSERT INTO payments (code, direction, counterparty_type, customer_id, amount_ccy, currency,
        fx_rate, amount_base, bank_account_code, payment_date)
    VALUES ('ZZFIX30-PAY-IN', 'in', 'customer', v_cust, 500, v_ccy, 1, 500, '1000', CURRENT_DATE)
    RETURNING id INTO v_je;
    INSERT INTO payment_allocations (payment_id, sales_record_id, allocated_base, allocated_ccy, allocated_pay)
    VALUES (v_je, v_sr, 500, 500, 500);                              -- ar_over_90 + invoice_overdue
    INSERT INTO payments (code, direction, counterparty_type, supplier_id, amount_ccy, currency,
        fx_rate, amount_base, bank_account_code, payment_date)
    VALUES ('ZZFIX30-PAY-OUT', 'out', 'supplier', v_sup, 1000, v_ccy, 1, 1000, '1000', CURRENT_DATE)
    RETURNING id INTO v_je;
    INSERT INTO payment_allocations (payment_id, inbound_batch_id, allocated_base, allocated_ccy, allocated_pay)
    VALUES (v_je, v_ib4, 1000, 1000, 1000);                          -- ap_over_90

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now;
    RESET ROLE;

    IF v_n <> 0 THEN
        PERFORM set_config('request.jwt.claims',
            format('{"sub":"%s","role":"authenticated"}', v_all), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT COALESCE(array_agg(DISTINCT item_type ORDER BY item_type), '{}') INTO v_types
          FROM operations_now;
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 30C 失败:十五个条件都已解除,应 0 行,实得 % 行(%)—— 赖着不走的支就是"处理完了牌子还亮着"的那一支',
            v_n, v_types::text;
    END IF;
END $$;
ROLLBACK;
