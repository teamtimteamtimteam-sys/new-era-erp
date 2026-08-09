-- 30 operations_now:条件成立时那一支【有】这一行,解除后【没有】;
--    只持一个模块的读者,恰好只看见那个模块的支
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
    v_ccy text;
    v_types text[];
    v_n int;
    v_expected text[] := ARRAY['allocation_stale','assay_unapplied','bank_unmatched',
        'claim_pending','fx_rate_gap','leave_pending','po_awaiting_receipt',
        'review_submitted','stocktake_open'];
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    -- 成本条目会触发自动应计过账 —— 锁不能挡住 fixture 自己的日期(回滚,无副作用)
    UPDATE finance_settings SET locked_before = NULL;

    -- ── 角色 ────────────────────────────────────────────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-30-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.inbound.view','module.processing.view',
        'module.purchasing.view','module.stocktakes.view','module.hr.view','module.finance.view']);
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
    INSERT INTO processing_runs (code, status, allocated_at)
    VALUES ('ZZFIX30-RUN', 'committed', '2027-01-01') RETURNING id INTO v_run;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, created_at, updated_at)
    VALUES (v_run, 'electricity', 100, '2027-02-01', '2027-02-01');

    -- 3 po_awaiting_receipt:已确认
    INSERT INTO purchase_orders (code, supplier_id, order_date, status)
    VALUES ('ZZFIX30-PO', v_sup, '2027-01-15', 'confirmed') RETURNING id INTO v_po;

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

    -- ══════════ A. 条件成立:九支【每支都在】════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(array_agg(DISTINCT item_type ORDER BY item_type), '{}') INTO v_types
      FROM operations_now;
    RESET ROLE;

    IF v_types <> v_expected THEN
        RAISE EXCEPTION 'FIXTURE 30A 失败:九支条件全部成立,应恰好看见 %,实得 % —— 少一支是条件恒假(那块牌子永远 0),多一支是支列表变了而 fixture 没跟上',
            v_expected::text, v_types::text;
    END IF;

    -- 每支恰好一件(本 fixture 的库里只有自己的数据 —— fixtures 各自回滚,互不遗留)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now;
    RESET ROLE;
    IF v_n <> 9 THEN
        RAISE EXCEPTION 'FIXTURE 30A 失败:应恰好 9 行(每支 1 件),实得 % 行', v_n;
    END IF;

    -- ══════════ B. 只持 inbound 的读者:恰好只看见 inbound 的支 ══════════════
    -- 其余八支此刻条件【全部成立】—— 缺席只能来自权限,不能来自碰巧没数据。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_inb), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(array_agg(DISTINCT item_type ORDER BY item_type), '{}') INTO v_types
      FROM operations_now;
    RESET ROLE;

    IF v_types <> ARRAY['assay_unapplied'] THEN
        RAISE EXCEPTION 'FIXTURE 30B 失败:只持 module.inbound.view 应恰好看见 {assay_unapplied},实得 % —— 多的支是权限裁决漏了(0 会冒充成一个真数字),少的支是把自己模块的也裁掉了',
            v_types::text;
    END IF;

    -- ══════════ C. 条件逐支解除:九支【每支都不在】═══════════════════════════
    UPDATE assay_results SET applied_at = now() WHERE id = v_ar;
    UPDATE processing_runs SET allocated_at = '2027-03-01' WHERE id = v_run;  -- 晚于成本变动
    UPDATE purchase_orders SET status = 'closed' WHERE id = v_po;
    UPDATE stocktakes SET status = 'cancelled' WHERE id = v_st;
    UPDATE leave_requests SET status = 'approved' WHERE id = v_lr;
    UPDATE medical_claims SET status = 'approved' WHERE id = v_mc;
    UPDATE performance_reviews SET status = 'approved' WHERE id = v_pr;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    SELECT 'USD', '2027-03-03', t, 1.3 FROM unnest(ARRAY['tt_buy','tt_sell','mid']) t;
    UPDATE bank_statement_lines SET match_status = 'ignored' WHERE id = v_bl;

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
        RAISE EXCEPTION 'FIXTURE 30C 失败:九个条件都已解除,应 0 行,实得 % 行(%)—— 赖着不走的支就是"处理完了牌子还亮着"的那一支',
            v_n, v_types::text;
    END IF;
END $$;
ROLLBACK;
