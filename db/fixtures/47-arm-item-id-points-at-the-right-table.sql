-- 47 看板每一支的门牌:item_id 落在【这一支该落的那张表】里
--
-- 【这一刀唯一能造出的无声失败】(LINKS-1)。接错的 join 给出的仍是一个合法 uuid,
-- 没有类型错误、没有约束冲突、没有 42501 —— 它只是【打开了别人的单据】。
-- 页面照样 200,链接照样能点,数字照样对。任何 gate 都看不见它:结构没变、
-- 镜像一致、路由冒烟只断言 2xx。所以它只能由行为断言来钉。
--
-- 【为什么不能断言"item_id 与 item_code 是同一行"】两支的 item_code 【按设计】
-- 指的是邻居而不是那一行自己:
--   * review_submitted —— 评估表没有 code 列,牌面上给的是【员工编号】;
--   * bank_unmatched —— 牌面上给的是【银行账户码】,而对账单行连 code 都没有。
-- 还有两支的 item_id 【按设计】指的是父:bank_unmatched 指对账单(行没有页面,
-- 匹配动作在对账工作台上)、margin_cost_not_allocated 指加工单(补救是分摊成本)。
-- 于是"一行一个 id"与"id 互不相同"都不能断言 —— 同一张对账单上的两条未匹配行
-- 本来就共用一个门牌,那是对的。
--
-- 【能断言的是这个】item_id 落在那一支该落的那张表里。接错表的 join 过不了它
-- (员工 id 冒充评估 id、化验 id 冒充批次 id 都会当场红),共用的父过得了。
-- 映射就是下面的 CASE —— 它同时是【规格】:新加一支若没在这里声明自己的表,
-- 本 fixture 直接失败,不是默默放行(check-i18n 的 MANIFEST 同一条纪律)。
--
-- 【A 臂先钉覆盖】二十支必须全部在场。少一支,它那条门牌断言就成了空转 ——
-- 而空转的断言与通过的断言在屏幕上一模一样(fixture 26 与 FIN-30 的老账)。
--
-- 【D 臂钉应付的两种单据】ap_over_90 是唯一按 doc_kind 分岔的支:进料批次去
-- /finance/payables/<id>,开支单去 /finance/expenses/<id>。只造一种单据,
-- 另一条分支就从未被走过 —— 所以两种都造,并断言两种都出现过。
--
-- 【故障注入(做过,不是打算做)】把 assay_unapplied 的 item_id 从 ib.id 改成
-- b.latest_assay_id —— 一个真实存在、合法、且【是错的】uuid。B 臂当场红,
-- 点名 assay_unapplied 与 inbound_batches。见提交说明。
--
-- 规格(每支的门牌、判据、以及两处例外)在 docs/dashboard-arm-inventory.md。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_mat uuid; v_sup uuid; v_sup_cert uuid; v_sup_none uuid;
    v_mat_asy uuid;   -- ASY-P1:awaiting_assay 专用的物料(只有它声明化验要求)
    v_cust uuid; v_cust2 uuid;
    v_ib1 uuid; v_ib2 uuid; v_ib3 uuid; v_ib4 uuid; v_ib_run uuid;
    v_run uuid; v_run_margin uuid; v_po uuid; v_st uuid; v_emp1 uuid; v_emp2 uuid;
    v_ob1 uuid; v_ob2 uuid; v_ob_margin uuid;
    v_sr uuid; v_inv uuid; v_bs uuid; v_je uuid;
    v_ccy text;
    v_rows jsonb;
    v_rec record;
    v_type text; v_kind text; v_code text; v_tbl text;
    v_id uuid; v_ok boolean; v_n int;
    v_types text[];
    v_kinds text[];
    v_expected text[] := ARRAY['allocation_stale','ap_over_90','ar_over_90',
        'assay_unapplied','awaiting_assay','bank_unmatched','batch_unpriced',
        'claim_pending','credit_over_limit','fx_rate_gap','invoice_overdue',
        'leave_pending','margin_cost_not_allocated','output_unsold_aging',
        'po_awaiting_receipt','qualification_expiring','qualification_missing',
        'review_submitted','safety_stock_below','stocktake_open'];
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    -- README 第 5 条:前提显式设定。成本条目会触发自动应计过账,锁不能挡住 fixture 的日期
    UPDATE finance_settings SET locked_before = NULL;

    -- ── 一个读者,持全部二十支需要的码 ───────────────────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-47-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    -- data.view_prices:三支财务支的行【存在性】挂在被它遮蔽的金额列上(见清单文件
    -- 的隐患二),缺了会静默少报而不是「受限」;margin 支本身也要它。
    -- SS-1:module.inventory.view —— safety_stock_below 挂在它上面。少了它,那一支
    -- 被外层的 has_permission 裁掉,A 臂会报"少一支",而真正的原因是【读者没权限】,
    -- 不是视图少了一支。两者的红长得一样,所以这一行的理由写在这里。
    SELECT r_all, unnest(ARRAY['module.inbound.view','module.processing.view',
        'module.processing.edit','module.purchasing.view','module.stocktakes.view',
        'module.hr.view','module.output.view','module.output.edit',
        'module.finance.view','module.suppliers.view','module.customers.view',
        'module.inventory.view','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    -- ── 主数据 ──────────────────────────────────────────────────────────────
    -- SS-1:阈值设在这份 fixture 的库存够不着的地方 —— 这一支因此必然在场。
    -- 【A 臂断言二十支全在】,少一支就意味着它那条门牌断言空转,而空转的断言
    -- 与通过的断言长得一模一样。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, safety_stock_qty)
    VALUES ('ZZFIX47-M', 'fixture 47 material', 'battery_material', true, 'black_mass', 'end_of_life', 999999) RETURNING id INTO v_mat;
    -- 【ASY-P1:awaiting_assay 只在物料声明了化验要求时才可能亮】给它一个专用物料,
    -- v_mat 上不声明 —— 否则 IB1 / IB3 会一起点亮这一支,而本 fixture 断言的是
    -- "每支恰好一件"。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX47-M-ASY', 'fixture 47 material (assay required)', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat_asy;
    INSERT INTO material_required_metals (material_id, metal) VALUES (v_mat_asy, 'cu');
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX47-S', 'fixture 47 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    -- 资质将到期的供应商:用 iso(warn,lead 60)—— warn 不挡收货,本 fixture 不需要
    -- 拦截语义,只需要这一支【上牌】。
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX47-S-CERT', 'fixture 47 cert supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup_cert;
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until)
    VALUES (v_sup_cert, 'iso', 'ZZFIX47-CERT', CURRENT_DATE - 365, CURRENT_DATE + 30);
    -- 一张证都没有的供应商(缺席臂)
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX47-S-NONE', 'fixture 47 no-cert supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup_none;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX47-C', 'fixture 47 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX47-C2', 'fixture 47 margin customer', 'SG') RETURNING id INTO v_cust2;

    -- ── 进料三支 ────────────────────────────────────────────────────────────
    -- arrival_date 必填:FIN-32 的台账行 business_date 有 CHECK,空着整个 INSERT 被拒
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX47-IB1', v_mat, v_sup, 10, 10, CURRENT_DATE - 5) RETURNING id INTO v_ib1;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date)
    VALUES ('ZZFIX47-AR1', v_ib1, CURRENT_DATE - 4);                 -- assay_unapplied
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX47-IB2', v_mat_asy, v_sup, 10, 10, CURRENT_DATE - 5) RETURNING id INTO v_ib2;
                                                    -- awaiting_assay(要求 cu,零化验,还有料)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, pricing_status)
    VALUES ('ZZFIX47-IB3', v_mat, v_sup, 10, 10, CURRENT_DATE - 5, 'unpriced') RETURNING id INTO v_ib3;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('ZZFIX47-AR3', v_ib3, CURRENT_DATE - 4, now());           -- batch_unpriced(化验已执行)

    -- ── allocation_stale:分摊早于成本变动 ──────────────────────────────────
    INSERT INTO processing_runs (code, status, allocated_at, allocation_basis)
    VALUES ('ZZFIX47-RUN', 'committed', now() - interval '10 days', 'metal_value') RETURNING id INTO v_run;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, created_at, updated_at)
    VALUES (v_run, 'electricity', 100, now(), now());

    -- ── po_awaiting_receipt / stocktake_open ────────────────────────────────
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status)
    VALUES ('ZZFIX47-PO', v_sup, CURRENT_DATE - 20, v_ccy, 1, 'confirmed') RETURNING id INTO v_po;
    INSERT INTO stocktakes (code) VALUES ('ZZFIX47-ST') RETURNING id INTO v_st;

    -- ── HR 三支 ─────────────────────────────────────────────────────────────
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZFIX47-E1', 'fixture 47 employee', 'full_time', 'office', CURRENT_DATE - 400)
    RETURNING id INTO v_emp1;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZFIX47-E2', 'fixture 47 reviewer', 'full_time', 'office', CURRENT_DATE - 400)
    RETURNING id INTO v_emp2;
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days)
    VALUES ('ZZFIX47-LR', v_emp1, 'sick', CURRENT_DATE + 10, CURRENT_DATE + 10, 1);
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd)
    VALUES ('ZZFIX47-MC', v_emp1, CURRENT_DATE - 3, EXTRACT(year FROM CURRENT_DATE)::int, 50);
    -- review_submitted:item_code 是【员工编号】,item_id 是【评估】—— 本 fixture 的
    -- 核心判别之一,员工 id 冒充评估 id 会被 B 臂当场抓住。
    INSERT INTO performance_reviews (employee_id, reviewer_employee_id, review_type,
        period_start, period_end, status, submitted_at, rating_code, summary_text, probation_outcome)
    VALUES (v_emp1, v_emp2, 'probation', CURRENT_DATE - 180, CURRENT_DATE - 30, 'submitted',
            now(), 'MEETS', 'fixture 47', 'confirm');

    -- ── AR / 发票 / 信用(同一个客户,同一笔销售)────────────────────────────
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX47-OB1', v_mat, 100, 100, CURRENT_DATE - 10) RETURNING id INTO v_ob1;
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
        currency, fx_rate, amount_base, sale_date)
    VALUES (v_ob1, v_cust, 10, 50, v_ccy, 1, 500, CURRENT_DATE - 200) RETURNING id INTO v_sr;
    INSERT INTO invoices (code, customer_id, issue_date, due_date, payment_terms_days,
        currency, subtotal_base, total_base, bill_to_snapshot)
    VALUES ('ZZFIX47-INV', v_cust, CURRENT_DATE - 200, CURRENT_DATE - 170, 30,
            v_ccy, 500, 500, '{}'::jsonb) RETURNING id INTO v_inv;
    INSERT INTO invoice_lines (invoice_id, sales_record_id, line_no, description,
        quantity, unit, unit_price, amount_base)
    VALUES (v_inv, v_sr, 1, 'fixture 47 line', 10, 'kg', 50, 500);
    -- 敞口 500,限额设在它之下 → credit_over_limit(限额【在销售之后】才设:
    -- record_output_sale 会拒超限的单,而这一笔是直插的历史单据)
    UPDATE customers SET credit_limit_base = 100 WHERE id = v_cust;

    -- ── output_unsold_aging:滞销 90 天 ─────────────────────────────────────
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX47-OB2', v_mat, 40, 40, CURRENT_DATE - 90) RETURNING id INTO v_ob2;

    -- ── ap_over_90 的【两种单据】─────────────────────────────────────────────
    -- 一:进料批次(已计价,到货 200 天前;化验已执行,免得污染进料三支)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX47-IB4', v_mat, v_sup, 10, 10, CURRENT_DATE - 200, 100) RETURNING id INTO v_ib4;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('ZZFIX47-AR4', v_ib4, CURRENT_DATE - 200, now());
    -- 二:挂账开支单(unpaid 必须有供应商且不能有银行科目 —— expenses_payment_shape)
    INSERT INTO expenses (code, expense_date, account_code, amount_ccy, currency, fx_rate,
        amount_base, payment_status, supplier_id)
    VALUES ('ZZFIX47-EXP', CURRENT_DATE - 200, '6100', 300, v_ccy, 1, 300, 'unpaid', v_sup);

    -- ── fx_rate_gap:未来的工作日有外币过账、无牌价 ──────────────────────────
    -- 【未来日期是有意的】本支限 rate_date >= CURRENT_DATE - 45,未来日期恒在界内,
    -- fixture 便不依赖"跑在哪一天"(同 fixture 30)。
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('ZZFIX47-JE', '2027-03-03', 'fixture 47 fx gap', 'manual') RETURNING id INTO v_je;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    SELECT v_je, a.id, x.d, x.c, 'USD', 100, 1.3
    FROM (VALUES ('1010', 130.0, 0.0), ('4000', 0.0, 130.0)) x(code, d, c)
    JOIN accounts a ON a.code = x.code;

    -- ── bank_unmatched:一张对账单,【两条】未匹配行 ─────────────────────────
    -- 两条是有意的:它们共用同一个 item_id(对账单),而那正是本 fixture 不能断言
    -- "id 互不相同"的原因 —— 共用的父是对的,不是重复。
    INSERT INTO bank_statements (code, bank_account_code, currency, period_start, period_end,
        opening_balance, closing_balance)
    VALUES ('ZZFIX47-BS', '1000', v_ccy, CURRENT_DATE - 30, CURRENT_DATE, 0, 20) RETURNING id INTO v_bs;
    INSERT INTO bank_statement_lines (statement_id, line_no, line_date, amount)
    VALUES (v_bs, 1, CURRENT_DATE - 10, 10), (v_bs, 2, CURRENT_DATE - 9, 10);

    -- ── margin_cost_not_allocated:有加工单、已售、成本【未分摊】───────────────
    -- 走 RPC 而不是直插:这一支要的是 processing_outputs 的真实形状(fixture 45 同款)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price)
    VALUES ('ZZFIX47-IB-RUN', v_mat, v_sup, 100, 100, CURRENT_DATE, 5) RETURNING id INTO v_ib_run;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    v_run_margin := commit_processing_run(CURRENT_DATE, 'fixture 47', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib_run, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 80)), 'weight');
    SELECT po.output_batch_id INTO v_ob_margin
      FROM processing_outputs po WHERE po.run_id = v_run_margin;
    IF v_ob_margin IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 47 前置失败:加工单 % 没有产出批 —— margin 支会缺席,而 A 臂会把它读成"支列表变了"', v_run_margin;
    END IF;
    -- 【故意不调 allocate_processing_costs】—— 那就是 no_unit_cost
    -- 卖给另一个客户:v_cust 此刻已超限,record_output_sale 会拒
    PERFORM record_output_sale(v_ob_margin, 10, 20, v_ccy, NULL, v_cust2, CURRENT_DATE,
                               NULL, 'manual', NULL);

    -- ══════════ 读回:切角色,走与真实读者相同的门(README 第 6 条)══════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT jsonb_agg(jsonb_build_object('t', item_type, 'k', doc_kind,
                                        'id', item_id, 'c', item_code, 's', subject))
      INTO v_rows FROM operations_now;
    RESET ROLE;
    -- 【门牌的解析回 postgres 做】问题是"这个 uuid 在不在那张表里",那是数据的事实;
    -- 用 authenticated 去解析,RLS 藏起来的一行会伪装成"解析不到",红得毫无意义。

    IF v_rows IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 47 前置失败:operations_now 一行都没读到 —— 后面每一条断言都会空转';
    END IF;

    -- ══════════ A. 覆盖:二十支必须全部在场 ═════════════════════════════════
    SELECT COALESCE(array_agg(DISTINCT e->>'t' ORDER BY e->>'t'), '{}')
      INTO v_types FROM jsonb_array_elements(v_rows) e;
    IF v_types <> v_expected THEN
        RAISE EXCEPTION 'FIXTURE 47A 失败:应恰好看见二十支 %,实得 % —— 少一支,它那条门牌断言就没跑过(空转的断言与通过的断言长得一模一样);多一支说明支列表变了而本 fixture 没跟上,规格见 docs/dashboard-arm-inventory.md',
            v_expected::text, v_types::text;
    END IF;

    -- ══════════ B. 门牌:item_id 落在这一支该落的那张表里 ════════════════════
    FOR v_rec IN SELECT e FROM jsonb_array_elements(v_rows) e LOOP
        v_type := v_rec.e->>'t';
        v_kind := v_rec.e->>'k';
        v_code := v_rec.e->>'c';
        v_id   := NULLIF(v_rec.e->>'id', '')::uuid;

        -- 【这张映射就是规格】新加一支没在这里声明自己的表 → 直接失败,不默认放行
        v_tbl := CASE v_type
            WHEN 'awaiting_assay'            THEN 'inbound_batches'
            WHEN 'assay_unapplied'           THEN 'inbound_batches'
            WHEN 'batch_unpriced'            THEN 'inbound_batches'
            WHEN 'allocation_stale'          THEN 'processing_runs'
            WHEN 'po_awaiting_receipt'       THEN 'purchase_orders'
            WHEN 'stocktake_open'            THEN 'stocktakes'
            WHEN 'qualification_expiring'    THEN 'suppliers'
            WHEN 'qualification_missing'     THEN 'suppliers'
            WHEN 'credit_over_limit'         THEN 'customers'
            WHEN 'output_unsold_aging'       THEN 'output_batches'
            -- EXEC-1a:行情陈旧的门牌指【最近那一条报价】。"这个金属"本身没有 id,
            -- 而人要去看、要接着往下录的就是那一行。
            WHEN 'metal_quote_stale'         THEN 'metal_prices'
            WHEN 'orders_unfulfilled'        THEN 'sales_orders'
            -- EXEC-3a:资质两支的门牌都指【供应商】—— 续证在 /suppliers/[id]/edit
            -- 上的 CompliancePanel(补救动作在那张页面上,这是本 fixture 的判据)。
            -- 工单两支指工单本身:改计划/收工都在工单详情页上。
            WHEN 'work_order_overdue'        THEN 'work_orders'
            WHEN 'work_order_variance_beyond' THEN 'work_orders'
            -- SS-1:补救动作在物料页上(改阈值,或从那里出发去补货)
            WHEN 'safety_stock_below'        THEN 'materials'
            WHEN 'leave_pending'             THEN 'leave_requests'
            WHEN 'claim_pending'             THEN 'medical_claims'
            WHEN 'review_submitted'          THEN 'performance_reviews'
            WHEN 'invoice_overdue'           THEN 'invoices'
            WHEN 'ar_over_90'                THEN 'sales_records'
            -- 唯一按种类分岔的一支:两条分支都要能走到(D 臂钉它)
            WHEN 'ap_over_90'                THEN CASE v_kind
                                                      WHEN 'inbound' THEN 'inbound_batches'
                                                      WHEN 'expense' THEN 'expenses'
                                                      ELSE NULL END
            -- 主体是一条【不存在的】牌价行 —— 没有 id 可指,这是唯一允许为空的一支
            WHEN 'fx_rate_gap'               THEN NULL
            -- 父,不是等待行:行没有页面,匹配动作在对账工作台上
            WHEN 'bank_unmatched'            THEN 'bank_statements'
            -- 父,不是等待行:补救是给加工单分摊成本
            WHEN 'margin_cost_not_allocated' THEN 'processing_runs'
            ELSE '<未声明>'
        END;

        IF v_tbl = '<未声明>' THEN
            RAISE EXCEPTION 'FIXTURE 47B 失败:支「%」没有在本 fixture 里声明自己的目标表 —— 加一支就要在这里加一行(与在 docs/dashboard-arm-inventory.md 加一行同一条纪律),否则它的门牌从来没有被检查过', v_type;
        END IF;

        IF v_type = 'fx_rate_gap' THEN
            IF v_id IS NOT NULL THEN
                RAISE EXCEPTION 'FIXTURE 47B 失败:fx_rate_gap 的 item_id 应为空(缺的那条牌价行没有 id),实得 % —— 若确实给了它一个 id,那个 id 指的一定是别的东西', v_id;
            END IF;
            CONTINUE;
        END IF;

        IF v_tbl IS NULL THEN
            RAISE EXCEPTION 'FIXTURE 47B 失败:ap_over_90 出现了认不出的 doc_kind「%」(单据 %)—— 页面据它选门牌,认不出就只能不给链接,而这里必须让它红,不能让它悄悄过去', v_kind, v_code;
        END IF;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'FIXTURE 47B 失败:支「%」(%)的 item_id 为空 —— 除 fx_rate_gap 外每一支都必须有门牌,否则那块牌子上的这一件事点不开', v_type, v_code;
        END IF;

        EXECUTE format('SELECT EXISTS(SELECT 1 FROM public.%I WHERE id = $1)', v_tbl)
           INTO v_ok USING v_id;
        IF NOT v_ok THEN
            RAISE EXCEPTION 'FIXTURE 47B 失败:支「%」的 item_id % 在 % 里找不到(item_code = %)—— 接错的 join 给出的仍是一个合法 uuid,页面照样 200、链接照样能点,打开的却是别人的单据',
                v_type, v_id, v_tbl, v_code;
        END IF;
    END LOOP;

    -- ══════════ C. 两支的门牌【按设计】指向父 —— 钉住,免得被"修正"════════
    -- bank_unmatched:两条未匹配行,同一张对账单 → 两行、一个 item_id。
    -- 【只看自己造的那张单】(README 第 2 条:每个用例自带数据)—— 重建库里只有这一张,
    -- 而对着 live 做回滚型试跑时那里另有未匹配行,不筛就会因为别人的数据红。
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(v_rows) e
     WHERE e->>'t' = 'bank_unmatched' AND e->>'s' = 'ZZFIX47-BS';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 47C 前置失败:本 fixture 造了两条未匹配行,ZZFIX47-BS 应有 2 行,实得 % —— 只有一行的话"共用父"这件事根本没被测到', v_n;
    END IF;
    SELECT count(DISTINCT e->>'id') INTO v_n
      FROM jsonb_array_elements(v_rows) e
     WHERE e->>'t' = 'bank_unmatched' AND e->>'s' = 'ZZFIX47-BS';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 47C 失败:同一张对账单上的两条未匹配行应共用一个 item_id(那是对的,不是重复),实得 % 个不同的 id', v_n;
    END IF;
    -- margin_cost_not_allocated:item_code 是产出批,item_id 是加工单 —— 两者不同源
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(v_rows) e
      JOIN output_batches ob ON ob.code = e->>'c'
     WHERE e->>'t' = 'margin_cost_not_allocated' AND (e->>'id')::uuid = ob.id;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 47C 失败:margin_cost_not_allocated 的 item_id 指到了【产出批】自己 —— 它应当指向加工单(分摊按钮在加工单页上);指对了表也可能指错了行,这一条钉的是后者';
    END IF;

    -- ══════════ D. 应付两种单据都走到了 ═════════════════════════════════════
    SELECT COALESCE(array_agg(DISTINCT e->>'k' ORDER BY e->>'k'), '{}') INTO v_kinds
      FROM jsonb_array_elements(v_rows) e WHERE e->>'t' = 'ap_over_90';
    IF v_kinds <> ARRAY['expense','inbound'] THEN
        RAISE EXCEPTION 'FIXTURE 47D 失败:ap_over_90 应同时出现两种单据(进料批次 + 挂账开支),实得 % —— 只造一种,另一条分支就从未被走过,而页面正是按它选门牌的',
            v_kinds::text;
    END IF;
END $$;
ROLLBACK;
